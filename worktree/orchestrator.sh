#!/bin/bash
# Orchestrator daemon — Manages worker lifecycle and task distribution
# Usage: orchestrator.sh [--interval N] [--once] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"
CONFIG_FILE="$SHARED_DIR/worktree.config.json"
LOG_FILE="$SHARED_DIR/orchestrator.log"
PID_FILE="$SHARED_DIR/orchestrator.pid"

# Defaults
POLL_INTERVAL=30
RUN_ONCE=false
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) POLL_INTERVAL="$2"; shift 2 ;;
    --once) RUN_ONCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: orchestrator.sh [--interval N] [--once] [--dry-run]"
      echo "  --interval N  Poll interval in seconds (default: 30)"
      echo "  --once        Run one cycle then exit"
      echo "  --dry-run     Show what would happen without launching workers"
      exit 0
      ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

notify_telegram() {
  local message="$1"
  local token="${TELEGRAM_BOT_TOKEN:-}"
  local chat_id="${TELEGRAM_CHAT_ID:-}"
  if [ -z "$token" ] || [ -z "$chat_id" ]; then return 0; fi
  local payload
  payload="$(jq -n --arg chat_id "$chat_id" --arg text "$message" \
    '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')"

  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    > /dev/null 2>&1 || true  # never block on notification failure
}


# Store PID
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"; log "Orchestrator stopped"; exit 0' EXIT INT TERM

log "Orchestrator started (PID: $$, interval: ${POLL_INTERVAL}s)"

# Read config
NUM_WORKERS=5
if [ -f "$CONFIG_FILE" ]; then
  NUM_WORKERS="$(jq -r '.workers // 5' "$CONFIG_FILE")"
fi

# Track worker PIDs: associative array worker_num -> pid
declare -A WORKER_PIDS

# Check if a worker is busy (has a running claude process)
is_worker_busy() {
  local worker_num="$1"
  local pid="${WORKER_PIDS[$worker_num]:-}"

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0  # busy
  fi

  # Clean up stale PID
  unset "WORKER_PIDS[$worker_num]" 2>/dev/null || true
  return 1  # idle
}

# Get list of idle workers
get_idle_workers() {
  local idle=()
  for i in $(seq 1 "$NUM_WORKERS"); do
    if ! is_worker_busy "$i"; then
      idle+=("$i")
    fi
  done
  echo "${idle[@]}"
}

# Count pending tasks
count_pending() {
  jq '[.tasks[] | select(.status == "pending")] | length' "$SHARED_DIR/dev-tasks.json" 2>/dev/null || echo 0
}

# Update PROGRESS.md with completed task info
update_progress() {
  local task_data="$1"
  local task_title
  task_title="$(echo "$task_data" | jq -r '.title')"
  local worker_id
  worker_id="$(echo "$task_data" | jq -r '.claimed_by')"
  local result
  result="$(echo "$task_data" | jq -r '.result')"

  # Append to progress (atomic via temp + mv not needed for append, just serialize access)
  {
    echo ""
    echo "### $worker_id — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "- Task: $task_title"
    echo "- Result: $result"
  } >> "$SHARED_DIR/PROGRESS.md"
}

# Main orchestration loop
orchestrate() {
  local pending
  pending="$(count_pending)"

  if [ "$pending" -eq 0 ]; then
    log "No pending tasks"
    return
  fi

  local idle_workers
  idle_workers="$(get_idle_workers)"

  if [ -z "$idle_workers" ]; then
    log "All workers busy ($pending tasks pending)"
    return
  fi

  log "Pending tasks: $pending | Idle workers: $idle_workers"

  for worker_num in $idle_workers; do
    # Check if there are still pending tasks
    pending="$(count_pending)"
    [ "$pending" -eq 0 ] && break

    local worker_id="worker-$worker_num"

    if [ "$DRY_RUN" = true ]; then
      log "[DRY-RUN] Would launch $worker_id"
      continue
    fi

    log "Launching $worker_id..."

    # Launch worker in background
    bash "$SCRIPT_DIR/launch-worker.sh" "$worker_num" \
      >> "$SHARED_DIR/$worker_id.log" 2>&1 &
    WORKER_PIDS[$worker_num]=$!

    log "$worker_id started (PID: ${WORKER_PIDS[$worker_num]})"

    # Small delay between launches to avoid race conditions on task claiming
    sleep 2
  done
}

# Enqueue a review task for a completed implementation task
enqueue_review() {
  local task_data="$1"
  local orig_title
  orig_title="$(echo "$task_data" | jq -r '.title')"
  local orig_worker
  orig_worker="$(echo "$task_data" | jq -r '.claimed_by')"
  local orig_files
  orig_files="$(echo "$task_data" | jq -r '.files // [] | join(",")')"
  local orig_desc
  orig_desc="$(echo "$task_data" | jq -r '.description // empty')"

  # Extract worker branch name (worker-1 -> worker/1)
  local worker_branch="${orig_worker/worker-/worker/}"

  local review_desc="Code review for: $orig_title (implemented by $orig_worker).

SETUP: First merge the implementation branch into your worktree:
  git merge $worker_branch --no-edit

REVIEW CHECKLIST:
1. TypeScript type safety - types match interfaces in lib/types/entity.ts
2. React patterns - proper hooks, no hardcoded values, key props on lists
3. Import paths all resolve correctly
4. No security issues (XSS, hardcoded secrets, injection)
5. Data files match EntityBase schema (spot check 2-3 files)
6. Responsive design with Tailwind
7. No dead code, console.logs, or TODOs

FOR EACH ISSUE: Fix it immediately. Categorize as Critical/Important/Minor.

AFTER REVIEW:
1. Run: npm run build (must pass)
2. Commit fixes with message: fix(review): [summary of fixes]"

  bash "$SCRIPT_DIR/task-queue.sh" add \
    "review: $orig_title" \
    --priority high \
    --files "$orig_files" \
    --description "$review_desc"

  log "Enqueued review for: $orig_title (from $orig_worker)"
}

# Check for completed tasks and update progress
check_completions() {
  local completed
  completed="$(jq -c '.tasks[] | select(.status == "completed" or .status == "failed")' \
    "$SHARED_DIR/dev-tasks.json" 2>/dev/null)" || return

  # Track which completions we've already logged (simple file-based)
  local tracked_file="$SHARED_DIR/.tracked-completions"
  touch "$tracked_file"

  echo "$completed" | while IFS= read -r task; do
    [ -z "$task" ] && continue
    local task_id
    task_id="$(echo "$task" | jq -r '.id')"

    if ! grep -q "$task_id" "$tracked_file" 2>/dev/null; then
      local result
      result="$(echo "$task" | jq -r '.result')"
      local title
      title="$(echo "$task" | jq -r '.title')"
      local worker
      worker="$(echo "$task" | jq -r '.claimed_by')"

      log "Task completed: $title ($result) by $worker"
      update_progress "$task"
      echo "$task_id" >> "$tracked_file"

      # Send Telegram notification
      if [ "$result" = "success" ]; then
        notify_telegram "✅ *Worker Done*
Task: ${title}
Worker: ${worker}
Result: success
Branch ready for review."
      else
        local reason
        reason="$(echo "$task" | jq -r '.reason // "unknown"')"
        notify_telegram "❌ *Worker Failed*
Task: ${title}
Worker: ${worker}
Reason: ${reason}
Check: .worktree-shared/${worker}.log"
      fi

      # Auto-enqueue review for successful non-review tasks
      if [ "$result" = "success" ] && [[ "$title" != review:* ]]; then
        enqueue_review "$task"
      fi

      # Trigger post-review pipeline when a review task completes successfully
      if [ "$result" = "success" ] && [[ "$title" == review:* ]]; then
        local orig_slug="${title#review: }"
        local pipeline_marker="pipeline:$orig_slug"

        # Only trigger once per slug (check tracked completions)
        if ! grep -q "$pipeline_marker" "$tracked_file" 2>/dev/null; then
          echo "$pipeline_marker" >> "$tracked_file"
          log "Triggering post-review pipeline for: $orig_slug"

          bash "$SCRIPT_DIR/post-review-pipeline.sh" "$orig_slug" \
            >> "$SHARED_DIR/pipeline-$orig_slug.log" 2>&1 &

          notify_telegram "🔄 *Pipeline Started*
Task: ${orig_slug}
Stages: Retrospective → Automation → PR → Loop Review → Improvement"
        fi
      fi
    fi
  done
}

# Run loop
while true; do
  orchestrate
  check_completions

  if [ "$RUN_ONCE" = true ]; then
    log "Single run complete, exiting"
    break
  fi

  sleep "$POLL_INTERVAL"
done
