#!/bin/bash
# GCP Self-Healing Daemon
# Monitors OpenClaw health on GCP VM, auto-fixes known issues
# Deploy to GCP VM, run via systemd timer
# Usage: gcp-health-daemon.sh [--once] [--dry-run] [--interval N]

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
SESSIONS_FILE="$OPENCLAW_HOME/agents/main/sessions/sessions.json"
CONTAINER_NAME="${OPENCLAW_CONTAINER:-openclaw-openclaw-gateway-1}"
LOG_FILE="/var/log/donut-health.log"
ALERT_METHOD="${ALERT_METHOD:-log}"  # log | telegram
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

# Thresholds
SESSIONS_MAX_SIZE_KB=1024    # 1MB — trigger cleanup
SESSIONS_MAX_KEYS=50         # Max session entries
DISK_WARN_PERCENT=85
DISK_CRITICAL_PERCENT=95
CPU_WARN_PERCENT=300         # 300% on 2-core = 150% per core
HEALTH_CHECK_TIMEOUT=10      # seconds

# Runtime options
DRY_RUN=false
RUN_ONCE=false
CHECK_INTERVAL=1800  # 30 minutes

while [ $# -gt 0 ]; do
  case "$1" in
    --once) RUN_ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --interval) CHECK_INTERVAL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: gcp-health-daemon.sh [--once] [--dry-run] [--interval N]"
      echo "  --once       Run one check then exit"
      echo "  --dry-run    Report issues but don't fix them"
      echo "  --interval N Check interval in seconds (default: 1800)"
      exit 0
      ;;
    *) shift ;;
  esac
done

# ─── Logging ────────────────────────────────────────────────

log() {
  local level="$1"; shift
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

alert() {
  local msg="$1"
  log "ALERT" "$msg"

  if [ "$ALERT_METHOD" = "telegram" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="$TELEGRAM_CHAT_ID" \
      -d text="[Donut Health] $msg" \
      -d parse_mode="Markdown" \
      --max-time 10 >/dev/null 2>&1 || log "WARN" "Failed to send Telegram alert"
  fi
}

action() {
  local desc="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN" "Would: $desc"
    return 0
  fi
  log "ACTION" "$desc"
  "$@"
}

# ─── Health Checks ──────────────────────────────────────────

check_sessions_json() {
  log "INFO" "Checking sessions.json..."

  if [ ! -f "$SESSIONS_FILE" ]; then
    log "INFO" "sessions.json not found (may be using container path)"
    # Try container path
    if command -v docker &>/dev/null; then
      local size
      size=$(docker exec "$CONTAINER_NAME" stat -c%s /home/node/.openclaw/agents/main/sessions/sessions.json 2>/dev/null || echo "0")
      local size_kb=$((size / 1024))

      if [ "$size_kb" -gt "$SESSIONS_MAX_SIZE_KB" ]; then
        alert "sessions.json in container is ${size_kb}KB (threshold: ${SESSIONS_MAX_SIZE_KB}KB)"
        action "Trim sessions.json in container" \
          docker exec "$CONTAINER_NAME" node -e "
const fs = require('fs');
const p = '/home/node/.openclaw/agents/main/sessions/sessions.json';
try {
  const data = JSON.parse(fs.readFileSync(p, 'utf8'));
  const keys = Object.keys(data);
  if (keys.length > $SESSIONS_MAX_KEYS) {
    // Keep only the newest entries
    const sorted = keys.sort((a,b) => {
      const ta = data[a]?.lastActivity || 0;
      const tb = data[b]?.lastActivity || 0;
      return tb - ta;
    });
    const keep = {};
    sorted.slice(0, $SESSIONS_MAX_KEYS).forEach(k => keep[k] = data[k]);
    fs.writeFileSync(p, JSON.stringify(keep, null, 2));
    console.log('Trimmed from ' + keys.length + ' to ' + Object.keys(keep).length + ' sessions');
  }
} catch(e) { console.error(e.message); }
"
        return
      fi
    fi
    return
  fi

  # Local file check
  local size_kb
  size_kb=$(du -k "$SESSIONS_FILE" 2>/dev/null | cut -f1 || echo "0")

  if [ "$size_kb" -gt "$SESSIONS_MAX_SIZE_KB" ]; then
    alert "sessions.json is ${size_kb}KB (threshold: ${SESSIONS_MAX_SIZE_KB}KB)"

    local key_count
    key_count=$(python3 -c "
import json
with open('$SESSIONS_FILE') as f:
    data = json.load(f)
print(len(data))
" 2>/dev/null || echo "0")

    if [ "$key_count" -gt "$SESSIONS_MAX_KEYS" ]; then
      action "Trim sessions.json from $key_count to $SESSIONS_MAX_KEYS entries" \
        python3 -c "
import json
from datetime import datetime, timedelta, timezone

with open('$SESSIONS_FILE') as f:
    data = json.load(f)

# Sort by last activity, keep newest
items = sorted(data.items(), key=lambda x: x[1].get('lastActivity', 0), reverse=True)
trimmed = dict(items[:$SESSIONS_MAX_KEYS])

with open('$SESSIONS_FILE', 'w') as f:
    json.dump(trimmed, f, indent=2)

print(f'Trimmed from {len(data)} to {len(trimmed)} sessions')
"
    fi
  else
    log "INFO" "sessions.json OK (${size_kb}KB, threshold: ${SESSIONS_MAX_SIZE_KB}KB)"
  fi
}

check_disk_usage() {
  log "INFO" "Checking disk usage..."

  local usage
  usage=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')

  if [ -z "$usage" ]; then
    log "WARN" "Could not determine disk usage"
    return
  fi

  if [ "$usage" -gt "$DISK_CRITICAL_PERCENT" ]; then
    alert "CRITICAL: Disk at ${usage}% — auto-cleaning Docker cache"
    action "Prune Docker system" docker system prune -f --volumes 2>/dev/null || true
    action "Clean journal logs" journalctl --vacuum-size=100M 2>/dev/null || true
  elif [ "$usage" -gt "$DISK_WARN_PERCENT" ]; then
    alert "WARNING: Disk at ${usage}% — cleaning old Docker images"
    action "Remove dangling Docker images" docker image prune -f 2>/dev/null || true
  else
    log "INFO" "Disk OK (${usage}%)"
  fi
}

check_openclaw_process() {
  log "INFO" "Checking OpenClaw process..."

  # Check if running as systemd service
  if systemctl is-active openclaw-node &>/dev/null; then
    log "INFO" "OpenClaw systemd service is active"
    return
  fi

  # Check if running as Docker container
  if command -v docker &>/dev/null; then
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_found")

    case "$state" in
      running)
        log "INFO" "OpenClaw container is running"
        ;;
      exited|dead)
        alert "OpenClaw container is $state — restarting"
        action "Restart OpenClaw container" docker restart "$CONTAINER_NAME"
        ;;
      not_found)
        log "WARN" "OpenClaw container not found (name: $CONTAINER_NAME)"
        ;;
      *)
        log "WARN" "OpenClaw container in unexpected state: $state"
        ;;
    esac
  else
    log "WARN" "Neither systemd service nor Docker found"
  fi
}

check_cpu_load() {
  log "INFO" "Checking CPU load..."

  # Get load average (1 min) * 100
  local load_pct
  load_pct=$(python3 -c "
import os
load1 = os.getloadavg()[0]
ncpu = os.cpu_count() or 1
print(int(load1 / ncpu * 100))
" 2>/dev/null || echo "0")

  if [ "$load_pct" -gt "$CPU_WARN_PERCENT" ]; then
    alert "CPU load at ${load_pct}% per core — checking for runaway processes"

    # Log top processes
    log "INFO" "Top processes by CPU:"
    ps aux --sort=-%cpu 2>/dev/null | head -6 >> "$LOG_FILE" || \
    ps aux 2>/dev/null | sort -nrk 3,3 | head -6 >> "$LOG_FILE" || true
  else
    log "INFO" "CPU OK (${load_pct}% per core)"
  fi
}

check_log_rotation() {
  log "INFO" "Checking log sizes..."

  # Check OpenClaw logs
  local log_dir="/tmp/openclaw"
  if [ -d "$log_dir" ]; then
    local total_size
    total_size=$(du -sm "$log_dir" 2>/dev/null | cut -f1 || echo "0")

    if [ "$total_size" -gt 500 ]; then
      alert "OpenClaw logs at ${total_size}MB — rotating"
      action "Compress old OpenClaw logs" \
        find "$log_dir" -name "*.log" -mtime +3 -exec gzip {} \; 2>/dev/null || true
      action "Remove very old OpenClaw logs" \
        find "$log_dir" -name "*.log.gz" -mtime +14 -delete 2>/dev/null || true
    else
      log "INFO" "OpenClaw logs OK (${total_size}MB)"
    fi
  fi
}

# ─── Main Loop ──────────────────────────────────────────────

main() {
  log "INFO" "═══ Health check started ═══"

  check_sessions_json
  check_disk_usage
  check_openclaw_process
  check_cpu_load
  check_log_rotation

  log "INFO" "═══ Health check complete ═══"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/donut-health.log"

if [ "$RUN_ONCE" = true ]; then
  main
  exit 0
fi

log "INFO" "Starting health daemon (interval: ${CHECK_INTERVAL}s, dry-run: $DRY_RUN)"

while true; do
  main
  sleep "$CHECK_INTERVAL"
done
