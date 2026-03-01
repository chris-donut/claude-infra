#!/bin/bash
# Clean teardown of all worktrees and shared resources
# Usage: teardown.sh [--keep-branches] [--keep-shared]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"

KEEP_BRANCHES=false
KEEP_SHARED=false

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-branches) KEEP_BRANCHES=true; shift ;;
    --keep-shared) KEEP_SHARED=true; shift ;;
    --help|-h)
      echo "Usage: teardown.sh [--keep-branches] [--keep-shared]"
      echo "  --keep-branches  Don't delete worker/* branches"
      echo "  --keep-shared    Don't delete .worktree-shared/"
      exit 0
      ;;
    *) shift ;;
  esac
done

echo "============================================"
echo "  Worktree Teardown"
echo "============================================"
echo ""

# 1. Stop daemons
echo "--- Stopping daemons ---"
for pidfile in "$SHARED_DIR/orchestrator.pid" "$SHARED_DIR/token-daemon.pid"; do
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    name="$(basename "$pidfile" .pid)"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      echo "  Stopped $name (PID: $pid)"
    else
      echo "  $name not running (stale PID: $pid)"
    fi
    rm -f "$pidfile"
  fi
done

# 2. Kill any running claude processes in worktrees
echo ""
echo "--- Stopping worker processes ---"
for worker_dir in "$WORKTREE_ROOT"/worker-*; do
  [ -d "$worker_dir" ] || continue
  worker_name="$(basename "$worker_dir")"

  # Find claude processes with this worktree as working directory
  pids="$(lsof +D "$worker_dir" 2>/dev/null | grep claude | awk '{print $2}' | sort -u)" || true
  if [ -n "$pids" ]; then
    echo "  Stopping claude in $worker_name (PIDs: $pids)"
    echo "$pids" | xargs kill 2>/dev/null || true
    sleep 1
  fi
done

# 3. Remove worktrees
echo ""
echo "--- Removing worktrees ---"
for worker_dir in "$WORKTREE_ROOT"/worker-*; do
  [ -d "$worker_dir" ] || continue
  worker_name="$(basename "$worker_dir")"

  # Remove symlinks first (git worktree remove doesn't like them)
  for link in "$worker_dir/dev-tasks.json" "$worker_dir/dev-task.lock" "$worker_dir/api-key.json"; do
    [ -L "$link" ] && rm -f "$link"
  done

  git -C "$REPO_ROOT" worktree remove "$worker_dir" --force 2>/dev/null || \
    rm -rf "$worker_dir"
  echo "  Removed $worker_name"
done

# Clean up worktree root
rmdir "$WORKTREE_ROOT" 2>/dev/null || true

# Prune stale worktree references
git -C "$REPO_ROOT" worktree prune 2>/dev/null || true

# 4. Delete worker branches
if [ "$KEEP_BRANCHES" = false ]; then
  echo ""
  echo "--- Deleting worker branches ---"
  for branch in $(git -C "$REPO_ROOT" branch --list 'worker/*' 2>/dev/null); do
    git -C "$REPO_ROOT" branch -D "$branch" 2>/dev/null && \
      echo "  Deleted $branch" || \
      echo "  Could not delete $branch"
  done
fi

# 5. Clean shared directory
if [ "$KEEP_SHARED" = false ]; then
  echo ""
  echo "--- Removing shared directory ---"
  rm -rf "$SHARED_DIR"
  echo "  Removed .worktree-shared/"
fi

echo ""
echo "============================================"
echo "  Teardown Complete"
echo "============================================"
echo ""
echo "Remaining worktrees:"
git -C "$REPO_ROOT" worktree list
