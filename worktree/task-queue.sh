#!/bin/bash
# Task Queue CLI — Atomic JSON task queue with flock
# Usage:
#   task-queue.sh add "title" [--priority high|medium|low] [--files "glob"] [--description "desc"] [--spec-file "path"] [--max-rounds N] [--parent-task "id"] [--project-id "id"] [--phase N]
#   task-queue.sh claim <worker_id>
#   task-queue.sh complete <task_id> --worker <worker_id> --result "success|failed" [--reason "..."]
#   task-queue.sh list [--status pending|claimed|completed|failed]
#   task-queue.sh status
#   task-queue.sh reset <task_id>
#   task-queue.sh update <task_id> --field <name> --value <val>
#   task-queue.sh dashboard

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="${WORKTREE_SHARED_DIR:-$REPO_ROOT/.worktree-shared}"
TASKS_FILE="$SHARED_DIR/dev-tasks.json"
LOCK_FILE="$SHARED_DIR/dev-task.lock"

# Portable flock wrapper (Linux flock / macOS shlock fallback)
if command -v flock &>/dev/null; then
  do_lock()   { flock "$LOCK_FILE" "$@"; }
  do_lock_sh(){ flock -s "$LOCK_FILE" "$@"; }
else
  # macOS fallback: use mkdir-based spinlock
  _acquire_lock() {
    local lockdir="$LOCK_FILE.d"
    while ! mkdir "$lockdir" 2>/dev/null; do sleep 0.05; done
    trap "_release_lock" EXIT
  }
  _release_lock() { rmdir "$LOCK_FILE.d" 2>/dev/null || true; }
  do_lock()   { _acquire_lock; "$@"; local rc=$?; _release_lock; return $rc; }
  do_lock_sh(){ do_lock "$@"; }
fi

# Ensure shared dir and files exist
ensure_init() {
  mkdir -p "$SHARED_DIR"
  [ -f "$LOCK_FILE" ] || touch "$LOCK_FILE"
  if [ ! -f "$TASKS_FILE" ]; then
    echo '{"version":1,"tasks":[]}' > "$TASKS_FILE"
  fi
}

locked_read() {
  do_lock_sh cat "$TASKS_FILE"
}

locked_write() {
  local jq_expr="$1"
  do_lock bash -c "
    tmp=\"\$(mktemp)\"
    jq '$jq_expr' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"
  "
}

# Generate a short unique task ID
gen_task_id() {
  echo "task-$(date +%s)-$$-$RANDOM"
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


# --- Commands ---

cmd_add() {
  local title=""
  local priority="medium"
  local files=""
  local description=""
  local spec_file=""
  local max_rounds="3"
  local parent_task=""
  local project_id=""
  local phase=""

  # Parse positional title
  if [ $# -gt 0 ] && [[ ! "$1" == --* ]]; then
    title="$1"
    shift
  fi

  # Parse flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --priority) priority="$2"; shift 2 ;;
      --files) files="$2"; shift 2 ;;
      --description) description="$2"; shift 2 ;;
      --spec-file) spec_file="$2"; shift 2 ;;
      --max-rounds) max_rounds="$2"; shift 2 ;;
      --parent-task) parent_task="$2"; shift 2 ;;
      --project-id) project_id="$2"; shift 2 ;;
      --phase) phase="$2"; shift 2 ;;
      *) echo "Unknown flag: $1"; exit 1 ;;
    esac
  done

  if [ -z "$title" ]; then
    echo "Error: task title required"
    echo "Usage: task-queue.sh add \"title\" [--priority high|medium|low] [--spec-file path]"
    exit 1
  fi

  local task_id
  task_id="$(gen_task_id)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build files array
  local files_json="[]"
  if [ -n "$files" ]; then
    files_json="$(echo "$files" | jq -R 'split(",")')"
  fi

  # Build parent_task_id (null or string)
  local parent_json="null"
  if [ -n "$parent_task" ]; then
    parent_json="\"$parent_task\""
  fi

  # Build project_id (null or string)
  local project_json="null"
  if [ -n "$project_id" ]; then
    project_json="\"$project_id\""
  fi

  # Build phase (null or number)
  local phase_json="null"
  if [ -n "$phase" ]; then
    phase_json="$phase"
  fi

  local task_json
  task_json="$(jq -n \
    --arg id "$task_id" \
    --arg title "$title" \
    --arg desc "$description" \
    --arg priority "$priority" \
    --arg created "$now" \
    --argjson files "$files_json" \
    --arg spec_file "$spec_file" \
    --argjson max_rounds "$max_rounds" \
    --argjson parent_task_id "$parent_json" \
    --argjson project_id "$project_json" \
    --argjson phase "$phase_json" \
    '{
      id: $id,
      title: $title,
      description: $desc,
      priority: $priority,
      status: "pending",
      claimed_by: null,
      claimed_at: null,
      completed_at: null,
      created_at: $created,
      files: $files,
      result: null,
      reason: null,
      round: 0,
      max_rounds: $max_rounds,
      parent_task_id: $parent_task_id,
      gate_results: null,
      feedback_file: null,
      spec_file: $spec_file,
      project_id: $project_id,
      phase: $phase
    }'
  )"

  do_lock bash -c "
    tmp=\"\$(mktemp)\"
    jq --argjson task '$task_json' '.tasks += [\$task]' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"
  "

  echo "Added task: $task_id — $title (priority: $priority)"

  # Send Telegram notification (non-blocking)
  notify_telegram "📋 *Task Queued*
${title}
Priority: ${priority}"
}

cmd_claim() {
  local worker_id="${1:-}"
  if [ -z "$worker_id" ]; then
    echo "Error: worker_id required"
    echo "Usage: task-queue.sh claim <worker_id>"
    exit 1
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Atomic claim: find first pending task (priority order: high > medium > low), assign to worker
  local result
  result="$(do_lock bash -c "
    # Priority sort: high=0, medium=1, low=2
    task_id=\$(jq -r '
      .tasks
      | map(select(.status == \"pending\"))
      | sort_by(
          if .priority == \"high\" then 0
          elif .priority == \"medium\" then 1
          else 2 end
        )
      | .[0].id // empty
    ' \"$TASKS_FILE\")

    if [ -z \"\$task_id\" ]; then
      echo 'NO_TASKS'
      exit 0
    fi

    tmp=\"\$(mktemp)\"
    jq --arg id \"\$task_id\" --arg worker \"$worker_id\" --arg now \"$now\" '
      .tasks |= map(
        if .id == \$id then
          .status = \"claimed\" | .claimed_by = \$worker | .claimed_at = \$now
        else . end
      )
    ' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"

    # Output the claimed task
    jq --arg id \"\$task_id\" '.tasks[] | select(.id == \$id)' \"$TASKS_FILE\"
  ")"

  if [ "$result" = "NO_TASKS" ]; then
    echo "No pending tasks available"
    return 1
  fi

  echo "$result"
}

cmd_complete() {
  local task_id="${1:-}"
  shift || true

  local worker_id=""
  local result_status=""
  local reason=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --worker) worker_id="$2"; shift 2 ;;
      --result) result_status="$2"; shift 2 ;;
      --reason) reason="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$task_id" ] || [ -z "$worker_id" ] || [ -z "$result_status" ]; then
    echo "Error: task_id, --worker, and --result required"
    echo "Usage: task-queue.sh complete <task_id> --worker <worker_id> --result success|failed"
    exit 1
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local new_status="completed"
  [ "$result_status" = "failed" ] && new_status="failed"

  do_lock bash -c "
    tmp=\"\$(mktemp)\"
    jq --arg id \"$task_id\" --arg worker \"$worker_id\" --arg status \"$new_status\" \
       --arg result \"$result_status\" --arg reason \"$reason\" --arg now \"$now\" '
      .tasks |= map(
        if .id == \$id and .claimed_by == \$worker then
          .status = \$status | .completed_at = \$now | .result = \$result | .reason = \$reason
        else . end
      )
    ' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"
  "

  echo "Task $task_id marked as $new_status by $worker_id"
}

cmd_list() {
  local filter_status="${1:-}"

  ensure_init

  if [ -n "$filter_status" ] && [[ "$filter_status" == --status ]]; then
    filter_status="${2:-}"
  fi

  if [ -n "$filter_status" ]; then
    locked_read | jq --arg s "$filter_status" '.tasks[] | select(.status == $s)' | jq -s '.'
  else
    locked_read | jq '.tasks'
  fi
}

cmd_status() {
  ensure_init

  local data
  data="$(locked_read)"

  local total pending claimed completed failed
  total="$(echo "$data" | jq '.tasks | length')"
  pending="$(echo "$data" | jq '[.tasks[] | select(.status == "pending")] | length')"
  claimed="$(echo "$data" | jq '[.tasks[] | select(.status == "claimed")] | length')"
  completed="$(echo "$data" | jq '[.tasks[] | select(.status == "completed")] | length')"
  failed="$(echo "$data" | jq '[.tasks[] | select(.status == "failed")] | length')"

  echo "=== Task Queue Status ==="
  echo "Total:     $total"
  echo "Pending:   $pending"
  echo "Claimed:   $claimed"
  echo "Completed: $completed"
  echo "Failed:    $failed"
  echo ""

  # Show claimed tasks with workers
  if [ "$claimed" -gt 0 ]; then
    echo "=== Active Workers ==="
    echo "$data" | jq -r '.tasks[] | select(.status == "claimed") | "  Worker \(.claimed_by): \(.title) (since \(.claimed_at))"'
  fi
}

cmd_reset() {
  local task_id="${1:-}"
  if [ -z "$task_id" ]; then
    echo "Error: task_id required"
    exit 1
  fi

  do_lock bash -c "
    tmp=\"\$(mktemp)\"
    jq --arg id \"$task_id\" '
      .tasks |= map(
        if .id == \$id then
          .status = \"pending\" | .claimed_by = null | .claimed_at = null |
          .completed_at = null | .result = null | .reason = null
        else . end
      )
    ' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"
  "

  echo "Task $task_id reset to pending"
}

cmd_update() {
  local task_id="${1:-}"
  shift || true

  local field=""
  local value=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --field) field="$2"; shift 2 ;;
      --value) value="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [ -z "$task_id" ] || [ -z "$field" ]; then
    echo "Error: task_id and --field required"
    echo "Usage: task-queue.sh update <task_id> --field <name> --value <val>"
    exit 1
  fi

  # Determine if value is a number or string
  local jq_set
  if echo "$value" | jq -e . >/dev/null 2>&1; then
    # Valid JSON (number, bool, null, array, object)
    jq_set=".\$field = ($value)"
  else
    # Treat as string
    jq_set=".\$field = \$value"
  fi

  do_lock bash -c "
    tmp=\"\$(mktemp)\"
    jq --arg id \"$task_id\" --arg field \"$field\" --arg value \"$value\" '
      .tasks |= map(
        if .id == \$id then
          .[\$field] = (if \$value == \"null\" then null
                       elif (\$value | test(\"^[0-9]+$\")) then (\$value | tonumber)
                       else \$value end)
        else . end
      )
    ' \"$TASKS_FILE\" > \"\$tmp\" && mv \"\$tmp\" \"$TASKS_FILE\"
  "

  echo "Task $task_id: $field = $value"
}

cmd_dashboard() {
  ensure_init

  local data
  data="$(locked_read)"

  echo "📊 Pipeline Dashboard"
  echo "═══════════════════════════════════════════"

  # Active tasks (claimed)
  local active
  active="$(echo "$data" | jq -r '.tasks[] | select(.status == "claimed") | "  ⏳ \(.title)\n     Worker: \(.claimed_by) | Since: \(.claimed_at)"')"
  if [ -n "$active" ]; then
    echo "ACTIVE:"
    echo "$active"
    echo ""
  fi

  # Pending tasks
  local pending
  pending="$(echo "$data" | jq -r '.tasks[] | select(.status == "pending") | "  📋 \(.title) [\(.priority)] round:\(.round // 0)/\(.max_rounds // 3)"')"
  if [ -n "$pending" ]; then
    echo "PENDING:"
    echo "$pending"
    echo ""
  fi

  # Recent completions (last 5)
  echo "RECENT:"
  echo "$data" | jq -r '
    [.tasks[] | select(.status == "completed" or .status == "failed")]
    | sort_by(.completed_at) | reverse | .[0:5][]
    | "  \(if .result == "success" then "✅" else "❌" end) \(.title) — \(.result) (\(.completed_at // "?"))"'

  echo ""
  echo "═══════════════════════════════════════════"

  # Summary counts
  local total pending_c claimed completed failed
  total="$(echo "$data" | jq '.tasks | length')"
  pending_c="$(echo "$data" | jq '[.tasks[] | select(.status == "pending")] | length')"
  claimed="$(echo "$data" | jq '[.tasks[] | select(.status == "claimed")] | length')"
  completed="$(echo "$data" | jq '[.tasks[] | select(.status == "completed")] | length')"
  failed="$(echo "$data" | jq '[.tasks[] | select(.status == "failed")] | length')"
  echo "Total: $total | Pending: $pending_c | Active: $claimed | Done: $completed | Failed: $failed"
}

# --- Main ---

ensure_init

case "${1:-help}" in
  add)       shift; cmd_add "$@" ;;
  claim)     shift; cmd_claim "$@" ;;
  complete)  shift; cmd_complete "$@" ;;
  list)      shift; cmd_list "$@" ;;
  status)    shift; cmd_status "$@" ;;
  reset)     shift; cmd_reset "$@" ;;
  update)    shift; cmd_update "$@" ;;
  dashboard) shift; cmd_dashboard "$@" ;;
  help|--help|-h)
    echo "Task Queue CLI — Atomic JSON task queue"
    echo ""
    echo "Commands:"
    echo "  add \"title\" [--priority high|medium|low] [--files \"glob\"] [--description \"desc\"] [--spec-file \"path\"] [--max-rounds N] [--parent-task \"id\"]"
    echo "  claim <worker_id>"
    echo "  complete <task_id> --worker <worker_id> --result success|failed [--reason \"...\"]"
    echo "  list [--status pending|claimed|completed|failed]"
    echo "  status"
    echo "  reset <task_id>"
    echo "  update <task_id> --field <name> --value <val>"
    echo "  dashboard"
    ;;
  *)
    echo "Unknown command: $1"
    echo "Run: task-queue.sh help"
    exit 1
    ;;
esac
