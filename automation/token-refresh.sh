#!/bin/bash
# OAuth Token Lifecycle Manager
# Manages gcloud + Anthropic API tokens with proactive refresh
# Usage: token-refresh.sh [--daemon] [--check] [--refresh-gcloud] [--interval N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_FILE="${LOG_FILE:-/tmp/donut-token-refresh.log}"
PID_FILE="/tmp/donut-token-refresh.pid"

# Config
CHECK_INTERVAL=900   # 15 minutes
GCLOUD_REFRESH_BEFORE=600  # Refresh gcloud token if <10min remaining

MODE="check"  # check | daemon | refresh-gcloud

while [ $# -gt 0 ]; do
  case "$1" in
    --daemon) MODE="daemon"; shift ;;
    --check) MODE="check"; shift ;;
    --refresh-gcloud) MODE="refresh-gcloud"; shift ;;
    --interval) CHECK_INTERVAL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: token-refresh.sh [--daemon] [--check] [--refresh-gcloud] [--interval N]"
      echo ""
      echo "Modes:"
      echo "  --check           One-time check of all tokens (default)"
      echo "  --daemon          Run continuously, refreshing tokens proactively"
      echo "  --refresh-gcloud  Force refresh gcloud OAuth token"
      echo ""
      echo "Options:"
      echo "  --interval N      Check interval in seconds for daemon mode (default: 900)"
      exit 0
      ;;
    *) shift ;;
  esac
done

# ─── Logging ────────────────────────────────────────────────

log() {
  local level="$1"; shift
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [token] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Token Checks ──────────────────────────────────────────

check_anthropic_key() {
  log "INFO" "Checking Anthropic API key..."

  local key="${ANTHROPIC_API_KEY:-}"

  # Check common locations
  if [ -z "$key" ]; then
    for loc in "$HOME/.anthropic/api_key" "$HOME/.config/anthropic/api_key" "/tmp/donut-tokens/ANTHROPIC_API_KEY.token"; do
      if [ -f "$loc" ]; then
        key=$(cat "$loc" 2>/dev/null)
        [ -n "$key" ] && break
      fi
    done
  fi

  if [ -z "$key" ]; then
    log "WARN" "No Anthropic API key found"
    return 1
  fi

  # Validate with lightweight request
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "x-api-key: $key" \
    -H "anthropic-version: 2023-06-01" \
    -H "Content-Type: application/json" \
    -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' \
    "https://api.anthropic.com/v1/messages" \
    --max-time 10 2>/dev/null) || status="000"

  case "$status" in
    200|429)  # 429 = rate limited but key is valid
      log "INFO" "Anthropic API key valid (status: $status)"
      return 0
      ;;
    401)
      log "ERROR" "Anthropic API key invalid (401 Unauthorized)"
      return 1
      ;;
    *)
      log "WARN" "Anthropic API returned $status (may be temporary)"
      return 1
      ;;
  esac
}

check_gcloud_token() {
  log "INFO" "Checking gcloud OAuth token..."

  if ! command -v gcloud &>/dev/null; then
    log "INFO" "gcloud not installed, skipping"
    return 0
  fi

  # Check if authenticated
  local account
  account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null || true)

  if [ -z "$account" ]; then
    log "ERROR" "No active gcloud account — run: gcloud auth login"
    return 1
  fi

  # Check token expiry
  local token_info
  token_info=$(gcloud auth print-access-token --format=json 2>/dev/null || echo "")

  if [ -z "$token_info" ]; then
    log "WARN" "Cannot get gcloud access token — may need re-auth"
    return 1
  fi

  # Try to get token expiry
  local expiry_epoch
  expiry_epoch=$(gcloud auth print-access-token --format="value(token_expiry)" 2>/dev/null || true)

  if [ -n "$expiry_epoch" ]; then
    local now_epoch
    now_epoch=$(date +%s)
    local remaining=$((expiry_epoch - now_epoch))

    if [ "$remaining" -lt 0 ]; then
      log "ERROR" "gcloud token expired ${remaining}s ago"
      return 1
    elif [ "$remaining" -lt "$GCLOUD_REFRESH_BEFORE" ]; then
      log "WARN" "gcloud token expires in ${remaining}s — refreshing"
      refresh_gcloud
      return $?
    else
      log "INFO" "gcloud token valid (expires in ${remaining}s, account: $account)"
      return 0
    fi
  else
    # Can't determine expiry, just check if token works
    local iap_test
    iap_test=$(gcloud compute instances list --limit=1 --format="value(name)" 2>/dev/null || echo "FAIL")

    if [ "$iap_test" = "FAIL" ]; then
      log "WARN" "gcloud token may be expired (API call failed)"
      return 1
    else
      log "INFO" "gcloud token working (account: $account)"
      return 0
    fi
  fi
}

refresh_gcloud() {
  log "INFO" "Refreshing gcloud token..."

  # Try non-interactive refresh first
  if gcloud auth print-access-token --quiet 2>/dev/null | head -1 | grep -q '^ya29'; then
    log "INFO" "gcloud token refreshed successfully"
    return 0
  fi

  # If application default credentials exist, use those
  if [ -f "$HOME/.config/gcloud/application_default_credentials.json" ]; then
    if gcloud auth application-default print-access-token 2>/dev/null | head -1 | grep -q '^ya29'; then
      log "INFO" "gcloud ADC token refreshed"
      return 0
    fi
  fi

  log "ERROR" "Cannot auto-refresh gcloud token — manual login required"
  log "ERROR" "Run: gcloud auth login --update-adc"
  return 1
}

check_gh_token() {
  log "INFO" "Checking GitHub CLI token..."

  if ! command -v gh &>/dev/null; then
    log "INFO" "gh not installed, skipping"
    return 0
  fi

  if gh auth status 2>/dev/null; then
    log "INFO" "GitHub CLI authenticated"
    return 0
  else
    log "WARN" "GitHub CLI not authenticated — run: gh auth login"
    return 1
  fi
}

# ─── Service Account Recommendation ────────────────────────

suggest_service_account() {
  if command -v gcloud &>/dev/null; then
    local sa_count
    sa_count=$(gcloud iam service-accounts list --format="value(email)" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$sa_count" -eq 0 ]; then
      log "INFO" ""
      log "INFO" "TIP: Create a service account to avoid OAuth expiration:"
      log "INFO" "  gcloud iam service-accounts create donut-agent \\"
      log "INFO" "    --display-name='Donut Agent' \\"
      log "INFO" "    --project=\$(gcloud config get-value project)"
      log "INFO" "  gcloud iam service-accounts keys create ~/sa-key.json \\"
      log "INFO" "    --iam-account=donut-agent@\$(gcloud config get-value project).iam.gserviceaccount.com"
      log "INFO" "  export GOOGLE_APPLICATION_CREDENTIALS=~/sa-key.json"
      log "INFO" ""
      log "INFO" "  Service account keys never expire (unlike OAuth tokens)."
    fi
  fi
}

# ─── Main ───────────────────────────────────────────────────

run_checks() {
  local failures=0

  check_anthropic_key || failures=$((failures + 1))
  check_gcloud_token || failures=$((failures + 1))
  check_gh_token || failures=$((failures + 1))

  if [ "$failures" -gt 0 ]; then
    log "WARN" "$failures token(s) need attention"
    suggest_service_account
  else
    log "INFO" "All tokens healthy"
  fi

  return "$failures"
}

case "$MODE" in
  check)
    run_checks
    ;;

  refresh-gcloud)
    refresh_gcloud
    ;;

  daemon)
    # PID management
    if [ -f "$PID_FILE" ]; then
      old_pid=$(cat "$PID_FILE" 2>/dev/null || true)
      if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        log "WARN" "Token daemon already running (PID: $old_pid)"
        exit 1
      fi
    fi

    echo $$ > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; log "INFO" "Token daemon stopped"; exit 0' EXIT INT TERM

    log "INFO" "Token daemon started (PID: $$, interval: ${CHECK_INTERVAL}s)"

    while true; do
      run_checks || true
      sleep "$CHECK_INTERVAL"
    done
    ;;
esac
