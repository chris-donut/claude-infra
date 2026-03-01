#!/bin/bash
# Generate git state context snapshot
# Outputs to .claude/context/git-state.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPO_ROOT/.claude/context/git-state.md"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$(dirname "$OUTPUT")"

BRANCH="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo "detached")"
REMOTE="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || echo "no remote")"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

# Count changes
STAGED=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
UNSTAGED=$(git -C "$REPO_ROOT" diff --name-only 2>/dev/null | wc -l | tr -d ' ')
UNTRACKED=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')

if [ "$STAGED" -eq 0 ] && [ "$UNSTAGED" -eq 0 ] && [ "$UNTRACKED" -eq 0 ]; then
  CLEAN="yes"
else
  CLEAN="no"
fi

cat > "$OUTPUT" << EOF
# Git State
Generated: $TIMESTAMP

## Current Branch
- Branch: $BRANCH
- HEAD: $HEAD_SHA
- Remote: $REMOTE

## Working Directory
- Clean: $CLEAN
- Staged changes: $STAGED
- Unstaged changes: $UNSTAGED
- Untracked files: $UNTRACKED

## Recent Commits (last 10)
\`\`\`
$(git -C "$REPO_ROOT" log --oneline -10 2>/dev/null || echo "no commits")
\`\`\`

## Active Branches (by recency)
\`\`\`
$(git -C "$REPO_ROOT" branch -a --sort=-committerdate 2>/dev/null | head -10 || echo "no branches")
\`\`\`
EOF

# Open PRs (only if gh is available and authenticated)
if command -v gh &>/dev/null; then
  echo "" >> "$OUTPUT"
  echo "## Open PRs" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
  gh pr list --state open --limit 10 2>/dev/null >> "$OUTPUT" || echo "gh not authenticated or no PRs" >> "$OUTPUT"
  echo '```' >> "$OUTPUT"
fi

# Diff summary if dirty
if [ "$CLEAN" = "no" ]; then
  echo "" >> "$OUTPUT"
  echo "## Diff Summary" >> "$OUTPUT"
  if [ "$STAGED" -gt 0 ]; then
    echo "### Staged" >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
    git -C "$REPO_ROOT" diff --cached --stat 2>/dev/null >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
  fi
  if [ "$UNSTAGED" -gt 0 ]; then
    echo "### Unstaged" >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
    git -C "$REPO_ROOT" diff --stat 2>/dev/null >> "$OUTPUT"
    echo '```' >> "$OUTPUT"
  fi
fi

echo "Generated git state context: $OUTPUT"
