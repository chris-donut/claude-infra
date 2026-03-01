#!/bin/bash
# Cloud Watchdog — Tailscale health + service auto-recovery
# Deploy to claude-code-server, run via systemd timer every 5 min
# Usage: cloud-watchdog.sh [--once] [--dry-run]

set -euo pipefail

LOG_FILE="/var/log/cloud-watchdog.log"
ALERT_LOG="/var/log/cloud-watchdog-alerts.log"
DRY_RUN=false
RUN_ONCE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --once) RUN_ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

log() {
  local level="$1"; shift
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [$level] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

alert() {
  log "ALERT" "$1"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$ALERT_LOG" 2>/dev/null || true
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

# ─── Infra Repo Sync ─────────────────────────────────────

sync_infra_repo() {
  local repo="/home/chrizhuu/claude-infra"
  [ -d "$repo/.git" ] || return 0

  # Run git as chrizhuu (service runs as root, git safe.directory blocks cross-user ops)
  local before after
  before=$(sudo -u chrizhuu git -C "$repo" rev-parse HEAD 2>/dev/null) || return 0
  sudo -u chrizhuu git -C "$repo" pull --ff-only --quiet 2>/dev/null || {
    log "WARN" "claude-infra git pull failed"
    return 0
  }
  after=$(sudo -u chrizhuu git -C "$repo" rev-parse HEAD 2>/dev/null) || return 0

  if [ "$before" != "$after" ]; then
    log "INFO" "claude-infra updated: ${before:0:7} → ${after:0:7}"
  fi
}

# ─── Tailscale Health ────────────────────────────────────

check_tailscale() {
  log "INFO" "Checking Tailscale..."

  # Is tailscaled running?
  if ! systemctl is-active tailscaled &>/dev/null; then
    alert "tailscaled not running — restarting"
    action "Restart tailscaled" sudo systemctl restart tailscaled
    sleep 5
  fi

  # Can we reach the network?
  local status
  status=$(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('BackendState', 'unknown'))
except:
    print('error')
" 2>/dev/null || echo "error")

  case "$status" in
    Running)
      log "INFO" "Tailscale OK (Running)"
      ;;
    NeedsLogin)
      alert "Tailscale needs re-authentication"
      # Cannot auto-fix, just alert
      ;;
    Stopped)
      alert "Tailscale stopped — bringing up"
      action "Tailscale up" sudo tailscale up
      sleep 5
      ;;
    *)
      alert "Tailscale unexpected state: $status"
      action "Restart tailscaled" sudo systemctl restart tailscaled
      sleep 5
      ;;
  esac

  # Verify connectivity to known peer (Mac)
  if ! tailscale ping --c 1 --timeout 10s 100.101.19.33 &>/dev/null; then
    log "WARN" "Cannot ping Mac — may be offline (not an error)"
  else
    log "INFO" "Tailscale peer connectivity OK"
  fi
}

# ─── Task API Health ─────────────────────────────────────

check_task_api() {
  log "INFO" "Checking task-api..."

  if ! systemctl is-active task-api &>/dev/null; then
    alert "task-api not running — restarting"
    action "Restart task-api" sudo systemctl restart task-api
    return
  fi

  # Verify it actually responds
  local response
  response=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer ${TASK_API_TOKEN:-donut-claude-server-2026}" \
    http://localhost:8080/status 2>/dev/null || echo "000")

  if [ "$response" = "200" ]; then
    log "INFO" "task-api responding (HTTP 200)"
  elif [ "$response" = "000" ]; then
    alert "task-api not responding — restarting"
    action "Restart task-api" sudo systemctl restart task-api
  else
    log "WARN" "task-api returned HTTP $response"
  fi
}

# ─── Tmux Services Health ────────────────────────────────

check_tmux_services() {
  log "INFO" "Checking tmux services..."

  # Run tmux checks as chrizhuu since tmux sessions belong to that user
  local SUDO_USER_CMD="sudo -u chrizhuu"

  local expected_services=("hub" "competitor-api" "investor-dashboard" "obs-server")
  local missing=()

  for svc in "${expected_services[@]}"; do
    if ! $SUDO_USER_CMD tmux has-session -t "$svc" 2>/dev/null; then
      missing+=("$svc")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    alert "Missing tmux services: ${missing[*]}"
    log "INFO" "Attempting to restart missing services..."

    for svc in "${missing[@]}"; do
      case "$svc" in
        hub)
          action "Restart hub" $SUDO_USER_CMD tmux new-session -d -s hub -c /home/chrizhuu/projects \
            "bun run donut-hub-server.ts"
          ;;
        competitor-api)
          action "Restart competitor-api" $SUDO_USER_CMD tmux new-session -d -s competitor-api -c /home/chrizhuu/projects/donut-intel-radar \
            "bun run src/index.ts"
          ;;
        investor-dashboard)
          action "Restart investor-dashboard" $SUDO_USER_CMD tmux new-session -d -s investor-dashboard -c /home/chrizhuu/projects/donut-investor-pipe \
            "bun run src/index.ts"
          ;;
        obs-server)
          action "Restart obs-server" $SUDO_USER_CMD tmux new-session -d -s obs-server -c /home/chrizhuu/projects/claude-code-hooks-multi-agent-observability/apps/server \
            "bun run src/index.ts"
          ;;
      esac
    done
  else
    log "INFO" "All ${#expected_services[@]} tmux services running"
  fi
}

# ─── Resource Health ─────────────────────────────────────

check_resources() {
  log "INFO" "Checking resources..."

  # Disk
  local disk_pct
  disk_pct=$(df / | tail -1 | awk '{print $5}' | tr -d '%')
  if [ "$disk_pct" -gt 90 ]; then
    alert "Disk at ${disk_pct}% — cleaning logs"
    action "Clean old claude logs" find /home/chrizhuu/claude-logs -name "*.log" -mtime +7 -delete 2>/dev/null || true
    action "Clean old tmp files" find /tmp -name "task-*.txt" -mtime +3 -delete 2>/dev/null || true
  else
    log "INFO" "Disk OK (${disk_pct}%)"
  fi

  # Memory
  local mem_avail
  mem_avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
  if [ "$mem_avail" -lt 256 ]; then
    alert "Low memory: ${mem_avail}MB available"
  else
    log "INFO" "Memory OK (${mem_avail}MB available)"
  fi
}

# ─── Main ────────────────────────────────────────────────

main() {
  log "INFO" "═══ Watchdog check started ═══"
  sync_infra_repo
  check_tailscale
  check_task_api
  check_tmux_services
  check_resources
  log "INFO" "═══ Watchdog check complete ═══"
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || LOG_FILE="/tmp/cloud-watchdog.log"
mkdir -p "$(dirname "$ALERT_LOG")" 2>/dev/null || ALERT_LOG="/tmp/cloud-watchdog-alerts.log"

if [ "$RUN_ONCE" = true ]; then
  main
  exit 0
fi

log "INFO" "Starting watchdog daemon (interval: 300s)"
while true; do
  main
  sleep 300
done
