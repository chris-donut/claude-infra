#!/bin/bash
# Pre-Deploy Validation Script
# Run before pushing to catch issues locally instead of in 58-deploy loops
# Usage: deploy-check.sh [--fix] [--skip-build]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIX_MODE=false
SKIP_BUILD=false
ERRORS=0
WARNINGS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FIX_MODE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --help|-h)
      echo "Usage: deploy-check.sh [--fix] [--skip-build]"
      echo "  --fix         Auto-fix linting issues"
      echo "  --skip-build  Skip the full build step (faster)"
      exit 0
      ;;
    *) shift ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "  [INFO] $1"; }

echo "═══════════════════════════════════════"
echo "  Pre-Deploy Validation"
echo "═══════════════════════════════════════"
echo ""

# ─── 1. Check for secrets in staged files ───────────────────

echo "1. Secrets Check"

# Check for common secret patterns in staged changes
SECRETS_FOUND=$(git -C "$REPO_ROOT" diff --cached --diff-filter=d -U0 2>/dev/null | \
  grep -iE '(sk-ant-|AKIA|ghp_|gho_|glpat-|xoxb-|xoxp-|-----BEGIN.*PRIVATE KEY)' 2>/dev/null | \
  head -5 || true)

if [ -n "$SECRETS_FOUND" ]; then
  fail "Potential secrets found in staged changes:"
  echo "$SECRETS_FOUND" | head -3
else
  pass "No secrets detected in staged changes"
fi

# Check for .env files being committed
ENV_STAGED=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | grep -E '\.env($|\.)' || true)
if [ -n "$ENV_STAGED" ]; then
  fail "Environment files staged for commit: $ENV_STAGED"
else
  pass "No .env files staged"
fi

echo ""

# ─── 2. TypeScript Check ───────────────────────────────────

echo "2. TypeScript Type Check"

# Find all tsconfig.json files (skip node_modules)
TS_CONFIGS=$(find "$REPO_ROOT" -name "tsconfig.json" -not -path "*/node_modules/*" -not -path "*/.worktree*" -maxdepth 3 2>/dev/null)

if [ -n "$TS_CONFIGS" ]; then
  TS_PASS=true
  while IFS= read -r tsconfig; do
    dir=$(dirname "$tsconfig")
    project_name=$(basename "$dir")

    # Check if there's a tsc available
    if [ -f "$dir/node_modules/.bin/tsc" ]; then
      if "$dir/node_modules/.bin/tsc" --noEmit --project "$tsconfig" 2>/dev/null; then
        pass "TypeScript: $project_name"
      else
        fail "TypeScript errors in $project_name"
        TS_PASS=false
      fi
    elif command -v npx &>/dev/null; then
      if (cd "$dir" && npx tsc --noEmit 2>/dev/null); then
        pass "TypeScript: $project_name"
      else
        fail "TypeScript errors in $project_name"
        TS_PASS=false
      fi
    else
      warn "No tsc available for $project_name"
    fi
  done <<< "$TS_CONFIGS"
else
  info "No TypeScript projects found"
fi

echo ""

# ─── 3. Lint Check ─────────────────────────────────────────

echo "3. Lint Check"

# Find ESLint configs
ESLINT_CONFIGS=$(find "$REPO_ROOT" -maxdepth 3 -not -path "*/node_modules/*" \( -name ".eslintrc*" -o -name "eslint.config.*" \) 2>/dev/null | head -5)

if [ -n "$ESLINT_CONFIGS" ]; then
  while IFS= read -r config; do
    [ -z "$config" ] && continue
    dir=$(dirname "$config")
    project_name=$(basename "$dir")

    # Skip if no node_modules (can't lint without deps)
    [ -d "$dir/node_modules" ] || { info "Skipping $project_name (no node_modules)"; continue; }

    if [ "$FIX_MODE" = true ]; then
      if (cd "$dir" && npx eslint . --fix 2>/dev/null); then
        pass "Lint (fixed): $project_name"
      else
        warn "Lint fix had issues in $project_name"
      fi
    else
      if (cd "$dir" && npx eslint . 2>/dev/null); then
        pass "Lint: $project_name"
      else
        fail "Lint errors in $project_name (run with --fix to auto-fix)"
      fi
    fi
  done <<< "$ESLINT_CONFIGS"
else
  info "No ESLint config found"
fi

echo ""

# ─── 4. Build Check ────────────────────────────────────────

echo "4. Build Check"

if [ "$SKIP_BUILD" = true ]; then
  info "Build skipped (--skip-build)"
else
  # Find package.json with build script
  BUILD_PROJECTS=$(find "$REPO_ROOT" -maxdepth 3 -name "package.json" -not -path "*/node_modules/*" -not -path "*/.worktree*" 2>/dev/null)

  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    dir=$(dirname "$pkg")
    project_name=$(basename "$dir")

    HAS_BUILD=$(python3 -c "
import json
with open('$pkg') as f:
    data = json.load(f)
print('yes' if 'build' in data.get('scripts', {}) else 'no')
" 2>/dev/null || echo "no")

    if [ "$HAS_BUILD" = "yes" ]; then
      if (cd "$dir" && npm run build 2>/dev/null); then
        pass "Build: $project_name"
      else
        fail "Build failed: $project_name"
      fi
    fi
  done <<< "$BUILD_PROJECTS"
fi

echo ""

# ─── 5. Git Status Check ───────────────────────────────────

echo "5. Git Hygiene"

# Check for merge conflict markers
CONFLICTS=$(git -C "$REPO_ROOT" diff --cached 2>/dev/null | grep -c '^+.*[<>=]\{7\}' || true)
if [ "$CONFLICTS" -gt 0 ]; then
  fail "Merge conflict markers found in staged files"
else
  pass "No merge conflict markers"
fi

# Check for console.log/debugger in staged changes (warn only)
DEBUG_LINES=$(git -C "$REPO_ROOT" diff --cached -U0 2>/dev/null | \
  grep -c '^+.*\(console\.log\|debugger\|TODO.*HACK\|FIXME.*HACK\)' || true)
if [ "$DEBUG_LINES" -gt 0 ]; then
  warn "$DEBUG_LINES debug statements in staged changes"
else
  pass "No debug statements in staged changes"
fi

# Check for large files
LARGE_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | while read -r f; do
  [ -f "$REPO_ROOT/$f" ] && size=$(wc -c < "$REPO_ROOT/$f" 2>/dev/null | tr -d ' ') && [ "$size" -gt 1048576 ] && echo "$f ($((size/1024))KB)"
done || true)
if [ -n "$LARGE_FILES" ]; then
  warn "Large files (>1MB) staged: $LARGE_FILES"
else
  pass "No large files staged"
fi

echo ""

# ─── Summary ────────────────────────────────────────────────

echo "═══════════════════════════════════════"
if [ "$ERRORS" -gt 0 ]; then
  echo -e "  ${RED}FAILED${NC}: $ERRORS errors, $WARNINGS warnings"
  echo "  Fix errors before deploying."
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo -e "  ${YELLOW}PASSED WITH WARNINGS${NC}: $WARNINGS warnings"
  echo "  Review warnings before deploying."
  exit 0
else
  echo -e "  ${GREEN}ALL CHECKS PASSED${NC}"
  echo "  Safe to deploy."
  exit 0
fi
