#!/bin/bash
# Morning Brief Generator
# Aggregates status from Linear, GitHub, GCP, and local state
# Usage: morning-brief.sh [--json]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="$REPO_ROOT/state"
CONTEXT_DIR="$REPO_ROOT/.claude/context"
OUTPUT="$CONTEXT_DIR/morning-brief.md"
JSON_MODE=false

[ "${1:-}" = "--json" ] && JSON_MODE=true

TIMESTAMP="$(date +"%Y-%m-%d %H:%M %Z")"
mkdir -p "$CONTEXT_DIR"

# ─── Helpers ────────────────────────────────────────────────

section() { echo -e "\n## $1" >> "$OUTPUT"; }
item() { echo "- $*" >> "$OUTPUT"; }
code_block() { echo '```' >> "$OUTPUT"; }

# ─── Start Brief ────────────────────────────────────────────

cat > "$OUTPUT" << EOF
# Morning Brief
Generated: $TIMESTAMP

EOF

# ─── 1. Critical Alerts ────────────────────────────────────

section "Critical Alerts"

ALERTS=0

# Check blocked items
if [ -f "$STATE_DIR/blocked-items.json" ]; then
  BLOCKED_COUNT=$(python3 -c "
import json
with open('$STATE_DIR/blocked-items.json') as f:
    data = json.load(f)
print(len(data.get('items', [])))
" 2>/dev/null || echo "0")
  if [ "$BLOCKED_COUNT" -gt 0 ]; then
    item "BLOCKED: $BLOCKED_COUNT items need attention (see state/blocked-items.json)"
    ALERTS=$((ALERTS + 1))
  fi
fi

# Check for stale work-in-progress (>24h old)
if [ -f "$STATE_DIR/work-in-progress.json" ]; then
  STALE=$(python3 -c "
import json
from datetime import datetime, timedelta, timezone
with open('$STATE_DIR/work-in-progress.json') as f:
    data = json.load(f)
cutoff = datetime.now(timezone.utc) - timedelta(hours=24)
stale = 0
for t in data.get('tasks', []):
    try:
        started = datetime.fromisoformat(t['started_at'].replace('Z', '+00:00'))
        if started < cutoff:
            stale += 1
    except (KeyError, ValueError):
        pass
print(stale)
" 2>/dev/null || echo "0")
  if [ "$STALE" -gt 0 ]; then
    item "STALE: $STALE tasks running >24h — may need intervention"
    ALERTS=$((ALERTS + 1))
  fi
fi

# Check disk usage (local)
DISK_USAGE=$(df -h "$REPO_ROOT" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
if [ -n "$DISK_USAGE" ] && [ "$DISK_USAGE" -gt 85 ]; then
  item "DISK: Local disk at ${DISK_USAGE}% — clean up needed"
  ALERTS=$((ALERTS + 1))
fi

[ "$ALERTS" -eq 0 ] && item "No critical alerts"

# ─── 2. Git Status ─────────────────────────────────────────

section "Git Status"

BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "detached")"
HEAD="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")"
STAGED=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
UNSTAGED=$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null | wc -l | tr -d ' ')

item "Branch: \`$BRANCH\` @ \`$HEAD\`"
if [ "$STAGED" -gt 0 ] || [ "$UNSTAGED" -gt 0 ]; then
  item "Dirty: $STAGED staged, $UNSTAGED unstaged"
else
  item "Clean working directory"
fi

# Recent commits (last 5)
echo "" >> "$OUTPUT"
echo "**Recent commits:**" >> "$OUTPUT"
code_block
git -C "$REPO_ROOT" log --oneline -5 2>/dev/null >> "$OUTPUT" || echo "no commits" >> "$OUTPUT"
code_block

# ─── 3. Open PRs ───────────────────────────────────────────

section "Open PRs"

if command -v gh &>/dev/null; then
  PR_LIST=$(gh pr list --state open --limit 10 --json number,title,updatedAt,reviewDecision 2>/dev/null) || PR_LIST="[]"
  PR_COUNT=$(echo "$PR_LIST" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  if [ "$PR_COUNT" -gt 0 ]; then
    echo "$PR_LIST" | python3 -c "
import json, sys
prs = json.load(sys.stdin)
for pr in prs:
    num = pr.get('number', '?')
    title = pr.get('title', 'untitled')[:60]
    review = pr.get('reviewDecision', 'PENDING') or 'PENDING'
    icon = {'APPROVED': 'ok', 'CHANGES_REQUESTED': '!!', 'PENDING': '...'}.get(review, '?')
    print(f'- [#{num}] [{icon}] {title}')
" >> "$OUTPUT" 2>/dev/null
  else
    item "No open PRs"
  fi
else
  item "gh CLI not available"
fi

# ─── 4. Linear Issues (via gh/API) ─────────────────────────

section "Linear Priorities"
item "(Use /linear or Linear MCP to fetch assigned issues)"
item "Quick check: https://linear.app/donutbrowser/my-issues"

# ─── 5. Active Tasks ───────────────────────────────────────

section "Active Tasks"

if [ -f "$STATE_DIR/work-in-progress.json" ]; then
  python3 -c "
import json
with open('$STATE_DIR/work-in-progress.json') as f:
    data = json.load(f)
tasks = data.get('tasks', [])
if tasks:
    for t in tasks:
        status = t.get('status', '?').upper()
        title = t.get('title', 'untitled')
        branch = t.get('branch', '?')
        print(f'- [{status}] {title} (branch: {branch})')
else:
    print('- No active tasks in state tracker')
" >> "$OUTPUT" 2>/dev/null || item "State file unreadable"
else
  item "No state tracker (state/work-in-progress.json missing)"
fi

# ─── 6. Recently Completed ─────────────────────────────────

section "Recently Completed (48h)"

if [ -f "$STATE_DIR/completed-tasks.json" ]; then
  python3 -c "
import json
from datetime import datetime, timedelta, timezone
with open('$STATE_DIR/completed-tasks.json') as f:
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
if recent:
    for t in recent:
        title = t.get('title', 'untitled')
        print(f'- [DONE] {title}')
else:
    print('- No completions in last 48h')
" >> "$OUTPUT" 2>/dev/null || item "State file unreadable"
else
  item "No completion tracker"
fi

# ─── 7. Last Session Context ───────────────────────────────

section "Last Session"

LAST_SESSION="$CONTEXT_DIR/last-session.md"
if [ -f "$LAST_SESSION" ]; then
  # Show first 10 lines of last session summary
  head -10 "$LAST_SESSION" >> "$OUTPUT" 2>/dev/null
else
  item "No session handoff found. First session of the day?"
fi

# ─── Output ─────────────────────────────────────────────────

echo ""
echo "Morning brief generated: $OUTPUT"
echo "───────────────────────────────────"
cat "$OUTPUT"
