#!/bin/bash
# Master setup — Create all worktrees and shared resources
# Usage: setup.sh [--workers N] [--no-daemon]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"

NUM_WORKERS=5
START_DAEMON=true

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --workers) NUM_WORKERS="$2"; shift 2 ;;
    --no-daemon) START_DAEMON=false; shift ;;
    --help|-h)
      echo "Usage: setup.sh [--workers N] [--no-daemon]"
      echo "  --workers N    Number of workers (default: 5)"
      echo "  --no-daemon    Don't start token refresh daemon"
      exit 0
      ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

echo "============================================"
echo "  Git Worktree Parallel Dev Setup"
echo "  Workers: $NUM_WORKERS"
echo "  Repo:    $REPO_ROOT"
echo "============================================"
echo ""

# 1. Check prerequisites
echo "--- Checking prerequisites ---"
for cmd in git jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' not found. Please install it first."
    exit 1
  fi
done
echo "All prerequisites met."
echo ""

# 2. Create shared directory and files
echo "--- Setting up shared directory ---"
mkdir -p "$SHARED_DIR"

if [ ! -f "$SHARED_DIR/dev-tasks.json" ]; then
  echo '{"version":1,"tasks":[]}' > "$SHARED_DIR/dev-tasks.json"
  echo "  Created dev-tasks.json"
fi

touch "$SHARED_DIR/dev-task.lock"
echo "  Created dev-task.lock"

if [ ! -f "$SHARED_DIR/api-key.json" ]; then
  echo '{}' > "$SHARED_DIR/api-key.json"
  chmod 600 "$SHARED_DIR/api-key.json"
  echo "  Created api-key.json"
fi

if [ ! -f "$SHARED_DIR/PROGRESS.md" ]; then
  cat > "$SHARED_DIR/PROGRESS.md" << EOF
# Parallel Development Progress

Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Workers: $NUM_WORKERS

---

EOF
  echo "  Created PROGRESS.md"
fi

# Create config
cat > "$SHARED_DIR/worktree.config.json" << EOF
{
  "workers": $NUM_WORKERS,
  "port_base": 5200,
  "main_repo": "$REPO_ROOT",
  "worktree_root": "$WORKTREE_ROOT",
  "shared_dir": "$SHARED_DIR",
  "branch_prefix": "worker/",
  "oauth_refresh_interval_sec": 1800,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
echo "  Created worktree.config.json"
echo ""

# 3. Create worktree root
mkdir -p "$WORKTREE_ROOT"

# 4. Initialize each worker
echo "--- Initializing workers ---"
for i in $(seq 1 "$NUM_WORKERS"); do
  bash "$SCRIPT_DIR/worker-init.sh" "$i"
  echo ""
done

# 5. Start token daemon (optional)
if [ "$START_DAEMON" = true ]; then
  echo "--- Starting token daemon ---"
  if [ -f "$SHARED_DIR/token-daemon.pid" ]; then
    old_pid=$(cat "$SHARED_DIR/token-daemon.pid")
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "  Token daemon already running (PID: $old_pid)"
    else
      rm -f "$SHARED_DIR/token-daemon.pid"
      bash "$SCRIPT_DIR/token-daemon.sh" &
      echo "  Started token daemon (PID: $!)"
    fi
  else
    bash "$SCRIPT_DIR/token-daemon.sh" &
    echo "  Started token daemon (PID: $!)"
  fi
  echo ""
fi

# 6. Summary
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
echo "Worktrees:"
git -C "$REPO_ROOT" worktree list
echo ""
echo "Quick start:"
echo "  # Add tasks to the queue:"
echo "  bash worktree/task-queue.sh add \"Task description\" --priority high"
echo ""
echo "  # Launch a single worker:"
echo "  bash worktree/launch-worker.sh 1"
echo ""
echo "  # Start the orchestrator (manages all workers):"
echo "  python3 worktree/orchestrator.py"
echo ""
echo "  # Or the legacy bash version:"
echo "  bash worktree/orchestrator.sh"
echo ""
echo "  # Check status:"
echo "  bash worktree/task-queue.sh status"
echo ""
echo "  # Tear down everything:"
echo "  bash worktree/teardown.sh"
