#!/bin/bash
# Master context generation script
# Runs all generators and validates output

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT_DIR="$REPO_ROOT/scripts/context-gen"
CONTEXT_DIR="$REPO_ROOT/.claude/context"
MANIFEST="$CONTEXT_DIR/context-manifest.json"

mkdir -p "$CONTEXT_DIR"

echo "Generating context snapshots..."

# Run each generator
FAILED=0

for script in generate-environment.sh generate-git-state.sh generate-wip.sh generate-architecture.sh; do
  script_path="$SCRIPT_DIR/$script"
  if [ -f "$script_path" ]; then
    if bash "$script_path" 2>/dev/null; then
      echo "  [OK] $script"
    else
      echo "  [FAIL] $script"
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  [MISSING] $script"
    FAILED=$((FAILED + 1))
  fi
done

# Validate output files exist and are non-empty
echo ""
echo "Validating context files..."

VALID=0
TOTAL=0

for ctx_file in environment.md git-state.md work-in-progress.md architecture.md; do
  TOTAL=$((TOTAL + 1))
  filepath="$CONTEXT_DIR/$ctx_file"
  if [ -f "$filepath" ] && [ -s "$filepath" ]; then
    echo "  [OK] $ctx_file ($(wc -c < "$filepath" | tr -d ' ') bytes)"
    VALID=$((VALID + 1))
  else
    echo "  [MISSING/EMPTY] $ctx_file"
  fi
done

# Generate manifest
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
GIT_HEAD="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"

cat > "$MANIFEST" << EOF
{
  "generated_at": "$TIMESTAMP",
  "git_head": "$GIT_HEAD",
  "files": {
    "environment": "$([ -f "$CONTEXT_DIR/environment.md" ] && echo "ok" || echo "missing")",
    "git_state": "$([ -f "$CONTEXT_DIR/git-state.md" ] && echo "ok" || echo "missing")",
    "work_in_progress": "$([ -f "$CONTEXT_DIR/work-in-progress.md" ] && echo "ok" || echo "missing")",
    "architecture": "$([ -f "$CONTEXT_DIR/architecture.md" ] && echo "ok" || echo "missing")"
  },
  "valid": $VALID,
  "total": $TOTAL
}
EOF

echo ""
echo "Context generation complete: $VALID/$TOTAL files valid, $FAILED generators failed"
echo "Manifest: $MANIFEST"

# Exit with error if any generator failed
[ "$FAILED" -eq 0 ] || exit 1
