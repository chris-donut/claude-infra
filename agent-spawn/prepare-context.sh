#!/bin/bash
# Assemble context package for a specific agent type
# Outputs assembled context to stdout (for prompt injection)
#
# Usage: prepare-context.sh <agent-type> [--task "description"]
#   agent-type: subagent | teammate | openclaw | autonomous

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTEXT_DIR="$REPO_ROOT/.claude/context"
STATE_DIR="$REPO_ROOT/state"
SCRIPT_DIR="$(dirname "$0")"

# Parse arguments
AGENT_TYPE="${1:-subagent}"
TASK_DESC=""
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      TASK_DESC="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Validate context first (regenerate if stale)
bash "$SCRIPT_DIR/validate-context.sh" >/dev/null 2>&1 || true

# Helper: read file if it exists
read_if_exists() {
  [ -f "$1" ] && cat "$1" || echo "(not available)"
}

# Assemble context based on agent type
echo "## Agent Context (auto-generated $(date -u +"%Y-%m-%dT%H:%M:%SZ"))"
echo ""

case "$AGENT_TYPE" in
  subagent)
    echo "### Architecture"
    read_if_exists "$CONTEXT_DIR/architecture.md"
    echo ""
    echo "### Git State"
    read_if_exists "$CONTEXT_DIR/git-state.md"
    echo ""
    echo "### Work In Progress"
    read_if_exists "$CONTEXT_DIR/work-in-progress.md"
    ;;

  teammate)
    echo "### Environment"
    read_if_exists "$CONTEXT_DIR/environment.md"
    echo ""
    echo "### Architecture"
    read_if_exists "$CONTEXT_DIR/architecture.md"
    echo ""
    echo "### Git State"
    read_if_exists "$CONTEXT_DIR/git-state.md"
    echo ""
    echo "### Work In Progress"
    read_if_exists "$CONTEXT_DIR/work-in-progress.md"
    ;;

  openclaw)
    # OpenClaw agents get SOUL.md + AGENTS.md + WIP + architecture
    OPENCLAW_DIR="$REPO_ROOT/openclaw/workspace"
    echo "### Agent Operating Manual"
    read_if_exists "$OPENCLAW_DIR/AGENTS.md"
    echo ""
    echo "### Architecture"
    read_if_exists "$CONTEXT_DIR/architecture.md"
    echo ""
    echo "### Work In Progress"
    read_if_exists "$CONTEXT_DIR/work-in-progress.md"
    ;;

  autonomous)
    # Autonomous agents get everything
    echo "### Environment"
    read_if_exists "$CONTEXT_DIR/environment.md"
    echo ""
    echo "### Architecture"
    read_if_exists "$CONTEXT_DIR/architecture.md"
    echo ""
    echo "### Git State"
    read_if_exists "$CONTEXT_DIR/git-state.md"
    echo ""
    echo "### Work In Progress"
    read_if_exists "$CONTEXT_DIR/work-in-progress.md"
    echo ""

    # Completed tasks for deduplication
    echo "### Completed Tasks (for deduplication)"
    if [ -f "$STATE_DIR/completed-tasks.json" ]; then
      python3 -c "
import json
with open('$STATE_DIR/completed-tasks.json') as f:
    data = json.load(f)
for t in data.get('tasks', []):
    print(f\"- {t.get('title', 'unknown')} (completed: {t.get('completed_at', 'unknown')})\")
" 2>/dev/null || echo "(unable to read)"
    fi
    echo ""

    # Latest feature report
    echo "### Latest Feature Report"
    latest_report="$(ls -t "$REPO_ROOT"/reports/prioritized-features-*.md 2>/dev/null | head -1)"
    if [ -n "$latest_report" ]; then
      read_if_exists "$latest_report"
    else
      echo "(no feature reports found)"
    fi
    ;;

  *)
    echo "Unknown agent type: $AGENT_TYPE"
    echo "Usage: prepare-context.sh <subagent|teammate|openclaw|autonomous>"
    exit 1
    ;;
esac

# Add task description if provided
if [ -n "$TASK_DESC" ]; then
  echo ""
  echo "---"
  echo ""
  echo "## Your Task"
  echo "$TASK_DESC"
fi
