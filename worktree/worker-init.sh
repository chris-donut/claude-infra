#!/bin/bash
# Initialize a single worker worktree
# Usage: worker-init.sh <worker_number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"
WORKTREE_ROOT="$REPO_ROOT/.worktrees"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

WORKER_NUM="${1:-}"
if [ -z "$WORKER_NUM" ]; then
  echo "Error: worker number required"
  echo "Usage: worker-init.sh <worker_number>"
  exit 1
fi

WORKER_ID="worker-$WORKER_NUM"
WORKER_DIR="$WORKTREE_ROOT/$WORKER_ID"
BRANCH="worker/$WORKER_NUM"
PORT=$((5200 + WORKER_NUM - 1))

echo "=== Initializing $WORKER_ID ==="
echo "  Branch: $BRANCH"
echo "  Port:   $PORT"
echo "  Dir:    $WORKER_DIR"

# 1. Create git worktree
if [ -d "$WORKER_DIR" ]; then
  echo "  Worktree already exists, skipping creation"
else
  echo "  Creating git worktree..."
  # Delete branch if it exists (from a previous run)
  git -C "$REPO_ROOT" branch -D "$BRANCH" 2>/dev/null || true
  git -C "$REPO_ROOT" worktree add "$WORKER_DIR" -b "$BRANCH" HEAD
fi

# 2. Create isolated data directory
mkdir -p "$WORKER_DIR/data"
echo "  Created data/"

# 3. Create symlinks to shared files
for shared_file in dev-tasks.json dev-task.lock api-key.json; do
  target="$SHARED_DIR/$shared_file"
  link="$WORKER_DIR/$shared_file"

  # Ensure shared file exists
  if [ ! -f "$target" ]; then
    case "$shared_file" in
      dev-tasks.json) echo '{"version":1,"tasks":[]}' > "$target" ;;
      dev-task.lock)  touch "$target" ;;
      api-key.json)   echo '{}' > "$target" ;;
    esac
  fi

  # Create symlink (remove existing if any)
  rm -f "$link"
  ln -s "$target" "$link"
  echo "  Symlinked $shared_file"
done

# 4. Generate worker CLAUDE.md from template
mkdir -p "$WORKER_DIR/.claude"
if [ -f "$TEMPLATE_DIR/worker-CLAUDE.md" ]; then
  sed \
    -e "s|{{WORKER_ID}}|$WORKER_ID|g" \
    -e "s|{{BRANCH}}|$BRANCH|g" \
    -e "s|{{PORT}}|$PORT|g" \
    -e "s|{{MAIN_REPO}}|$REPO_ROOT|g" \
    "$TEMPLATE_DIR/worker-CLAUDE.md" > "$WORKER_DIR/.claude/CLAUDE.md"
  echo "  Generated .claude/CLAUDE.md"
else
  echo "  Warning: template not found at $TEMPLATE_DIR/worker-CLAUDE.md"
fi

# 5. Generate context files (if generate-all.sh exists and supports REPO_ROOT override)
if [ -x "$REPO_ROOT/scripts/context-gen/generate-all.sh" ]; then
  echo "  Generating context files..."
  REPO_ROOT="$WORKER_DIR" bash "$REPO_ROOT/scripts/context-gen/generate-all.sh" 2>/dev/null || \
    echo "  Warning: context generation failed (non-critical)"
fi

# 6. Create .gitignore for worker-local files
cat > "$WORKER_DIR/data/.gitignore" << 'EOF'
*
!.gitignore
EOF

echo "=== $WORKER_ID initialized ==="
