#!/bin/bash
# Claude Max OAuth Token Keepalive Daemon
# Monitors ~/.claude/.credentials.json and proactively refreshes before expiry.
# Claude CLI auto-refreshes access tokens using the refresh token on any API call,
# so we trigger a minimal CLI invocation when the token is about to expire.
#
# Usage:
#   token-daemon.sh [--once]           # Single check (for systemd timer / cron)
#   token-daemon.sh [--interval N]     # Continuous daemon mode
#
# Designed to run on GCP claude-code-server via systemd timer (recommended)
# or as a long-running daemon.

set -euo pipefail

CREDENTIALS_FILE="$HOME/.claude/.credentials.json"
LOG_DIR="/var/log/donut"
LOG_FILE="${LOG_DIR}/token-daemon.log"
ALERT_FILE="/tmp/donut-token-alert"

# Refresh when access token has less than this many seconds remaining
REFRESH_THRESHOLD=7200  # 2 hours

# Defaults
REFRESH_INTERVAL=1800  # 30 minutes (daemon mode only)
RUN_ONCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) REFRESH_INTERVAL="$2"; shift 2 ;;
    --once) RUN_ONCE=true; shift ;;
    --help|-h)
      echo "Usage: token-daemon.sh [--once] [--interval N]"
      echo "  --once        Single check then exit (for systemd timer)"
      echo "  --interval N  Daemon mode check interval in seconds (default: 1800)"
      exit 0
      ;;
    *) shift ;;
  esac
done

# ─── Logging ─────────────────────────────────────────────────

mkdir -p "$LOG_DIR" 2>/dev/null || LOG_FILE="/tmp/donut-token-daemon.log"

log() {
  local level="$1"; shift
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [token-daemon] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

alert() {
  log "ALERT" "$1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" > "$ALERT_FILE"
}

clear_alert() {
  rm -f "$ALERT_FILE" 2>/dev/null || true
}

# ─── Credentials Reader ─────────────────────────────────────

# Read expiresAt (ms) from credentials file. Returns empty on failure.
get_expires_at_ms() {
  if [ ! -f "$CREDENTIALS_FILE" ]; then
    return 1
  fi
  python3 -c "
import json, sys
try:
    with open('$CREDENTIALS_FILE') as f:
        d = json.load(f)
    oauth = d.get('claudeAiOauth', d)
    print(oauth.get('expiresAt', ''))
except:
    sys.exit(1)
" 2>/dev/null
}

# Returns seconds until access token expires. Negative = already expired.
get_remaining_seconds() {
  local expires_ms
  expires_ms="$(get_expires_at_ms)" || { echo "-1"; return; }

  if [ -z "$expires_ms" ]; then
    echo "-1"
    return
  fi

  python3 -c "
import time
expires_s = int($expires_ms) / 1000
remaining = expires_s - time.time()
print(int(remaining))
" 2>/dev/null || echo "-1"
}

# Check if credentials file exists and has valid structure
check_credentials_exist() {
  if [ ! -f "$CREDENTIALS_FILE" ]; then
    log "ERROR" "No credentials file: $CREDENTIALS_FILE"
    log "ERROR" "Run: claude login (interactively on this server)"
    return 1
  fi

  local has_refresh
  has_refresh="$(python3 -c "
import json
with open('$CREDENTIALS_FILE') as f:
    d = json.load(f)
oauth = d.get('claudeAiOauth', d)
print('yes' if oauth.get('refreshToken') else 'no')
" 2>/dev/null)" || has_refresh="no"

  if [ "$has_refresh" != "yes" ]; then
    log "ERROR" "No refresh token in credentials — OAuth login incomplete"
    return 1
  fi

  return 0
}

# ─── Proactive Refresh ──────────────────────────────────────

# Trigger Claude CLI to make an API call, which auto-refreshes the access token.
# Uses the cheapest possible invocation.
trigger_refresh() {
  log "INFO" "Triggering proactive token refresh via Claude CLI..."

  local old_expires_ms
  old_expires_ms="$(get_expires_at_ms)" || old_expires_ms=""

  # claude -p with minimal prompt triggers the auth flow
  # --max-turns 1 ensures it exits after one response
  # Timeout after 30s to avoid hanging
  if timeout 30 claude -p "." --max-turns 1 --output-format json > /dev/null 2>&1; then
    local new_expires_ms
    new_expires_ms="$(get_expires_at_ms)" || new_expires_ms=""

    if [ -n "$new_expires_ms" ] && [ "$new_expires_ms" != "$old_expires_ms" ]; then
      local new_remaining
      new_remaining="$(get_remaining_seconds)"
      log "INFO" "Token refreshed successfully (new expiry: ${new_remaining}s / $((new_remaining / 3600))h)"
      clear_alert
      return 0
    elif [ -n "$new_expires_ms" ]; then
      # expiresAt didn't change — token might still be valid enough that CLI didn't refresh
      local remaining
      remaining="$(get_remaining_seconds)"
      if [ "$remaining" -gt 0 ]; then
        log "INFO" "Token still valid (${remaining}s / $((remaining / 3600))h remaining), CLI did not refresh"
        clear_alert
        return 0
      fi
    fi
  fi

  log "ERROR" "Refresh trigger failed — CLI invocation did not update credentials"
  return 1
}

# ─── Main Check ──────────────────────────────────────────────

run_check() {
  log "INFO" "── Token health check ──"

  # 1. Credentials file exists?
  if ! check_credentials_exist; then
    alert "Claude credentials missing or invalid — manual login required"
    return 1
  fi

  # 2. Check remaining time
  local remaining
  remaining="$(get_remaining_seconds)"

  if [ "$remaining" -le 0 ]; then
    log "WARN" "Access token EXPIRED (${remaining}s ago)"

    # Try refresh — CLI should use refresh token even if access token is dead
    if trigger_refresh; then
      log "INFO" "Recovery successful after expiry"
      return 0
    else
      alert "Access token expired and refresh failed — run: claude login"
      return 1
    fi

  elif [ "$remaining" -lt "$REFRESH_THRESHOLD" ]; then
    log "INFO" "Access token expiring soon (${remaining}s / $((remaining / 3600))h remaining, threshold: ${REFRESH_THRESHOLD}s)"

    if trigger_refresh; then
      return 0
    else
      log "WARN" "Proactive refresh failed — will retry next cycle"
      return 1
    fi

  else
    local hours=$((remaining / 3600))
    local mins=$(((remaining % 3600) / 60))
    log "INFO" "Access token healthy (${hours}h ${mins}m remaining)"
    clear_alert
    return 0
  fi
}

# ─── Entry Point ─────────────────────────────────────────────

if [ "$RUN_ONCE" = true ]; then
  run_check
  exit $?
fi

# Daemon mode
log "INFO" "Token daemon started (PID: $$, interval: ${REFRESH_INTERVAL}s, threshold: ${REFRESH_THRESHOLD}s)"

while true; do
  run_check || true
  sleep "$REFRESH_INTERVAL"
done
