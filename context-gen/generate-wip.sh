#!/bin/bash
# Generate work-in-progress context snapshot
# Outputs to .claude/context/work-in-progress.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPO_ROOT/.claude/context/work-in-progress.md"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
STATE_DIR="$REPO_ROOT/state"

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" << EOF
# Work In Progress
Generated: $TIMESTAMP

EOF

# Active tasks from state/work-in-progress.json
WIP_FILE="$STATE_DIR/work-in-progress.json"
if [ -f "$WIP_FILE" ]; then
  echo "## Active Tasks" >> "$OUTPUT"
  # Parse JSON with python3 (available on macOS)
  python3 -c "
import json, sys
with open('$WIP_FILE') as f:
    data = json.load(f)
for t in data.get('tasks', []):
    status = t.get('status', 'unknown').upper()
    title = t.get('title', 'untitled')
    branch = t.get('branch', 'unknown')
    started = t.get('started_at', 'unknown')
    print(f'- [{status}] {title} - branch: {branch} - started: {started}')
if not data.get('tasks'):
    print('- No active tasks')
" >> "$OUTPUT" 2>/dev/null || echo "- No active tasks (state file unreadable)" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
fi

# Blocked items from state/blocked-items.json
BLOCKED_FILE="$STATE_DIR/blocked-items.json"
if [ -f "$BLOCKED_FILE" ]; then
  echo "## Known Blockers" >> "$OUTPUT"
  python3 -c "
import json
with open('$BLOCKED_FILE') as f:
    data = json.load(f)
for item in data.get('items', []):
    desc = item.get('description', 'unknown')
    retries = item.get('retry_count', 0)
    cooldown = item.get('cooldown_until', 'none')
    print(f'- {desc} (retries: {retries}, cooldown until: {cooldown})')
if not data.get('items'):
    print('- No blockers')
" >> "$OUTPUT" 2>/dev/null || echo "- No blockers (state file unreadable)" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
fi

# Recent completions from state/completed-tasks.json (last 48h)
COMPLETED_FILE="$STATE_DIR/completed-tasks.json"
if [ -f "$COMPLETED_FILE" ]; then
  echo "## Recently Completed (last 48h)" >> "$OUTPUT"
  python3 -c "
import json
from datetime import datetime, timedelta, timezone
with open('$COMPLETED_FILE') as f:
    data = json.load(f)
cutoff = datetime.now(timezone.utc) - timedelta(hours=48)
recent = []
for t in data.get('tasks', []):
    try:
        completed = datetime.fromisoformat(t['completed_at'].replace('Z', '+00:00'))
        if completed > cutoff:
            recent.append(t)
    except (KeyError, ValueError):
        pass
for t in recent:
    title = t.get('title', 'untitled')
    pr = t.get('pr_url', 'no PR')
    print(f'- [DONE] {title} - PR: {pr}')
if not recent:
    print('- No recent completions')
" >> "$OUTPUT" 2>/dev/null || echo "- No recent completions (state file unreadable)" >> "$OUTPUT"
  echo "" >> "$OUTPUT"
fi

# Open PRs
if command -v gh &>/dev/null; then
  echo "## Open PRs" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  gh pr list --state open --limit 5 2>/dev/null >> "$OUTPUT" || echo "gh not authenticated" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  echo "" >> "$OUTPUT"
fi

# Pending plan files
echo "## Pending Plans" >> "$OUTPUT"
PLANS_FOUND=false
for plan_dir in "$REPO_ROOT/.claude/plans" "$REPO_ROOT/docs/plans"; do
  if [ -d "$plan_dir" ]; then
    for plan in "$plan_dir"/*.md; do
      [ -f "$plan" ] || continue
      name="$(basename "$plan")"
      [ "$name" = "CLAUDE.md" ] && continue
      modified="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$plan" 2>/dev/null || echo "unknown")"
      echo "- $name (modified: $modified)" >> "$OUTPUT"
      PLANS_FOUND=true
    done
  fi
done
if [ "$PLANS_FOUND" = false ]; then
  echo "- No pending plans" >> "$OUTPUT"
fi

# Recent session log entries
SESSION_LOG="$STATE_DIR/session-log.jsonl"
if [ -f "$SESSION_LOG" ]; then
  echo "" >> "$OUTPUT"
  echo "## Recent Session Events (last 5)" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  tail -5 "$SESSION_LOG" >> "$OUTPUT" 2>/dev/null || echo "empty" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
fi

echo "Generated WIP context: $OUTPUT"
