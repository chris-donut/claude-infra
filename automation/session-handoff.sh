#!/bin/bash
# Session Context Handoff
# Saves a session summary for the next session to pick up
# Run at the end of each Claude Code session (or via hook)
# Usage: session-handoff.sh [--message "what I was working on"]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTEXT_DIR="$REPO_ROOT/.claude/context"
OUTPUT="$CONTEXT_DIR/last-session.md"
ARCHIVE_DIR="$CONTEXT_DIR/session-archive"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
LOCAL_TIME="$(date +"%Y-%m-%d %H:%M %Z")"

MESSAGE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --message|-m) MESSAGE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: session-handoff.sh [--message 'what I was working on']"
      echo "  Without --message, auto-generates from git state"
      exit 0
      ;;
    *) shift ;;
  esac
done

mkdir -p "$CONTEXT_DIR" "$ARCHIVE_DIR"

# Archive previous session if exists
if [ -f "$OUTPUT" ]; then
  PREV_DATE=$(head -5 "$OUTPUT" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || echo "unknown")
  mv "$OUTPUT" "$ARCHIVE_DIR/session-${PREV_DATE:-old}-$(date +%s).md" 2>/dev/null || true

  # Keep only last 10 archives
  ls -t "$ARCHIVE_DIR"/session-*.md 2>/dev/null | tail -n +11 | xargs rm -f 2>/dev/null || true
fi

# ─── Gather State ───────────────────────────────────────────

BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "unknown")"
HEAD="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "?")"

# Recent commits in this session (last 2 hours)
RECENT_COMMITS=$(git -C "$REPO_ROOT" log --oneline --since="2 hours ago" 2>/dev/null || echo "none")

# Uncommitted changes summary
STAGED=$(git -C "$REPO_ROOT" diff --cached --stat 2>/dev/null || true)
UNSTAGED=$(git -C "$REPO_ROOT" diff --stat 2>/dev/null || true)

# Modified files (for context on what areas were touched)
MODIFIED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | head -20 || true)
STAGED_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | head -20 || true)

# Active tasks
ACTIVE_TASKS=""
if [ -f "$REPO_ROOT/state/work-in-progress.json" ]; then
  ACTIVE_TASKS=$(python3 -c "
import json
with open('$REPO_ROOT/state/work-in-progress.json') as f:
    data = json.load(f)
for t in data.get('tasks', []):
    print(f\"- [{t.get('status','?').upper()}] {t.get('title','untitled')}\")
" 2>/dev/null || true)
fi

# Blocked items
BLOCKERS=""
if [ -f "$REPO_ROOT/state/blocked-items.json" ]; then
  BLOCKERS=$(python3 -c "
import json
with open('$REPO_ROOT/state/blocked-items.json') as f:
    data = json.load(f)
for item in data.get('items', []):
    print(f\"- {item.get('description','unknown')}\")
" 2>/dev/null || true)
fi

# ─── Generate Handoff ──────────────────────────────────────

cat > "$OUTPUT" << EOF
# Session Handoff
Saved: $LOCAL_TIME (UTC: $TIMESTAMP)

## Where I Left Off
- **Branch**: \`$BRANCH\` @ \`$HEAD\`
EOF

if [ -n "$MESSAGE" ]; then
  echo "- **Context**: $MESSAGE" >> "$OUTPUT"
fi

cat >> "$OUTPUT" << EOF

## Commits This Session
\`\`\`
${RECENT_COMMITS:-No commits in last 2 hours}
\`\`\`

## Uncommitted Work
EOF

if [ -n "$STAGED_FILES" ]; then
  echo "**Staged:**" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  echo "$STAGED" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
fi

if [ -n "$MODIFIED_FILES" ]; then
  echo "**Modified (unstaged):**" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  echo "$UNSTAGED" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
else
  echo "Clean working directory." >> "$OUTPUT"
fi

if [ -n "$ACTIVE_TASKS" ]; then
  cat >> "$OUTPUT" << EOF

## Active Tasks
$ACTIVE_TASKS
EOF
fi

if [ -n "$BLOCKERS" ]; then
  cat >> "$OUTPUT" << EOF

## Known Blockers
$BLOCKERS
EOF
fi

cat >> "$OUTPUT" << EOF

## Files Touched
\`\`\`
$(echo "$MODIFIED_FILES" "$STAGED_FILES" | sort -u | head -20)
\`\`\`
EOF

echo "Session handoff saved: $OUTPUT"
echo "────────────────────────────────"
cat "$OUTPUT"
