#!/bin/bash
# Validate context freshness before agent spawn
# Exit codes: 0=fresh, 1=stale (regenerated), 2=failed
#
# Usage: validate-context.sh [--max-age MINUTES]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTEXT_DIR="$REPO_ROOT/.claude/context"
MANIFEST="$CONTEXT_DIR/context-manifest.json"
MAX_AGE_MINUTES="${1:-30}"  # Default: 30 minutes

# Required context files
REQUIRED_FILES=(
  "environment.md"
  "git-state.md"
  "work-in-progress.md"
  "architecture.md"
)

echo "Validating agent context (max age: ${MAX_AGE_MINUTES}m)..."

# Check if context directory exists
if [ ! -d "$CONTEXT_DIR" ]; then
  echo "  Context directory missing. Generating..."
  if bash "$REPO_ROOT/scripts/context-gen/generate-all.sh"; then
    echo "  Context generated successfully."
    exit 1  # Stale, but regenerated
  else
    echo "  ERROR: Context generation failed."
    exit 2
  fi
fi

# Check each required file
STALE=false
MISSING=false

for file in "${REQUIRED_FILES[@]}"; do
  filepath="$CONTEXT_DIR/$file"

  if [ ! -f "$filepath" ]; then
    echo "  [MISSING] $file"
    MISSING=true
    continue
  fi

  if [ ! -s "$filepath" ]; then
    echo "  [EMPTY] $file"
    MISSING=true
    continue
  fi

  # Check age (macOS stat)
  file_mod="$(stat -f "%m" "$filepath" 2>/dev/null || echo "0")"
  now="$(date +%s)"
  age_seconds=$((now - file_mod))
  age_minutes=$((age_seconds / 60))

  if [ "$age_minutes" -gt "$MAX_AGE_MINUTES" ]; then
    echo "  [STALE] $file (${age_minutes}m old)"
    STALE=true
  else
    echo "  [OK] $file (${age_minutes}m old)"
  fi
done

# Check git HEAD consistency
if [ -f "$CONTEXT_DIR/git-state.md" ]; then
  current_head="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
  context_head="$(grep "HEAD:" "$CONTEXT_DIR/git-state.md" 2>/dev/null | head -1 | awk '{print $NF}' || echo "unknown")"

  if [ "$current_head" != "$context_head" ] && [ "$context_head" != "unknown" ]; then
    echo "  [STALE] git HEAD mismatch: context=$context_head current=$current_head"
    STALE=true
  fi
fi

# If missing or stale, regenerate
if [ "$MISSING" = true ] || [ "$STALE" = true ]; then
  echo ""
  echo "Context is stale or incomplete. Regenerating..."
  if bash "$REPO_ROOT/scripts/context-gen/generate-all.sh"; then
    echo "Context regenerated successfully."
    exit 1  # Was stale, now fresh
  else
    echo "ERROR: Context regeneration failed."
    exit 2
  fi
fi

echo ""
echo "Context is fresh and valid."
exit 0
