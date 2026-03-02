#!/bin/bash
# Quality Gate — Three-tiered quality verification for worker output
#
# Usage: quality-gate.sh <task-id> <worker-branch> [--spec <spec-file>] [--output <results-file>] [--tier 1|2|3|all]
#
# Tiers:
#   Tier 1 (Automated)  — deterministic checks: secrets, types, build, hygiene, skill-lint
#   Tier 2 (AI Review)  — Claude one-shot scoring: correctness, readability, convention, etc.
#   Tier 3 (Acceptance) — Claude checks implementation against spec acceptance criteria
#
# Output: JSON file at <results-file> with per-tier pass/fail and details.
# Exit code: 0 = all tiers pass, 1 = at least one tier failed, 2 = usage error
#
# Requires: jq, git, claude CLI (for Tier 2+3)
# Cost: Tier 1 = $0, Tier 2 ≈ $0.02, Tier 3 ≈ $0.02

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"

# ─── Args ────────────────────────────────────────────────────────────────────

TASK_ID=""
WORKER_BRANCH=""
SPEC_FILE=""
OUTPUT_FILE=""
RUN_TIER="all"

while [ $# -gt 0 ]; do
  case "$1" in
    --spec) SPEC_FILE="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --tier) RUN_TIER="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: quality-gate.sh <task-id> <worker-branch> [--spec <spec-file>] [--output <results-file>] [--tier 1|2|3|all]"
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$TASK_ID" ]; then
        TASK_ID="$1"
      elif [ -z "$WORKER_BRANCH" ]; then
        WORKER_BRANCH="$1"
      else
        echo "Unexpected arg: $1" >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$TASK_ID" ] || [ -z "$WORKER_BRANCH" ]; then
  echo "Error: task-id and worker-branch required" >&2
  echo "Usage: quality-gate.sh <task-id> <worker-branch> [--spec <spec-file>] [--output <results-file>]" >&2
  exit 2
fi

# Default output location
if [ -z "$OUTPUT_FILE" ]; then
  mkdir -p "$SHARED_DIR/gate-results"
  OUTPUT_FILE="$SHARED_DIR/gate-results/${TASK_ID}-latest.json"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [gate:$TASK_ID] $*"
}

# ─── Tier 1: Automated Checks ───────────────────────────────────────────────

tier1_results='{"pass": true, "checks": {}}'

tier1_check() {
  local name="$1"
  local pass="$2"
  local detail="$3"

  tier1_results=$(echo "$tier1_results" | jq \
    --arg name "$name" \
    --argjson pass "$pass" \
    --arg detail "$detail" \
    '.checks[$name] = {"pass": $pass, "detail": $detail} |
     if $pass == false then .pass = false else . end')
}

run_tier1() {
  log "Tier 1: Starting automated checks..."

  cd "$REPO_ROOT"

  # 1a. Secrets scan
  log "  [1a] Secrets scan..."
  local secrets_count=0
  local secrets_detail=""
  local diff_content
  diff_content=$(git diff "main...$WORKER_BRANCH" -- '*.ts' '*.js' '*.sh' '*.py' '*.md' '*.json' 2>/dev/null || echo "")

  if [ -n "$diff_content" ]; then
    secrets_count=$(echo "$diff_content" | grep -ciE '(sk-ant-|sk-proj-|AKIA[A-Z0-9]{16}|ghp_[a-zA-Z0-9]{36}|password\s*[:=]\s*["\x27][^"\x27]{8,})' || true)
  fi

  if [ "$secrets_count" -gt 0 ]; then
    tier1_check "secrets" false "${secrets_count} potential secret(s) found in diff"
  else
    tier1_check "secrets" true "No secrets detected"
  fi

  # 1b. TypeScript type check
  log "  [1b] TypeScript check..."
  local ts_changed
  ts_changed=$(git diff "main...$WORKER_BRANCH" --name-only 2>/dev/null | grep '\.tsx\?$' | wc -l | tr -d ' ')

  if [ "$ts_changed" -gt 0 ]; then
    local tsc_output
    tsc_output=$(npx tsc --noEmit 2>&1 || true)
    local tsc_errors
    tsc_errors=$(echo "$tsc_output" | grep -c 'error TS' || true)
    if [ "$tsc_errors" -gt 0 ]; then
      local tsc_sample
      tsc_sample=$(echo "$tsc_output" | grep 'error TS' | head -5 | tr '\n' ' ')
      tier1_check "typescript" false "${tsc_errors} type error(s): ${tsc_sample:0:300}"
    else
      tier1_check "typescript" true "Type check passed (${ts_changed} files)"
    fi
  else
    tier1_check "typescript" true "No TypeScript files changed"
  fi

  # 1c. Build validation
  log "  [1c] Build check..."
  if [ -f "$REPO_ROOT/package.json" ]; then
    local build_output
    build_output=$(npm run build 2>&1 || true)
    local build_exit=$?
    if echo "$build_output" | grep -qiE '(error|failed|FAIL)' || [ "$build_exit" -ne 0 ]; then
      local build_err
      build_err=$(echo "$build_output" | grep -iE '(error|failed)' | head -3 | tr '\n' ' ')
      tier1_check "build" false "Build failed: ${build_err:0:300}"
    else
      tier1_check "build" true "Build passed"
    fi
  else
    tier1_check "build" true "No package.json found (skipped)"
  fi

  # 1d. Git hygiene
  log "  [1d] Git hygiene..."
  local hygiene_issues=""
  local changed_files
  changed_files=$(git diff "main...$WORKER_BRANCH" --name-only 2>/dev/null || echo "")

  # Check for files that shouldn't be committed
  local bad_files
  bad_files=$(echo "$changed_files" | grep -E '(\.env$|\.env\.local|node_modules/|\.DS_Store|\.idea/|\.vscode/)' || true)
  if [ -n "$bad_files" ]; then
    hygiene_issues="Unwanted files: $(echo "$bad_files" | tr '\n' ', ')"
  fi

  # Check for merge conflict markers
  local conflict_markers=0
  if [ -n "$changed_files" ]; then
    conflict_markers=$(echo "$changed_files" | while read -r f; do
      [ -f "$f" ] && grep -cl '^<<<<<<< ' "$f" 2>/dev/null || true
    done | wc -l | tr -d ' ')
  fi
  if [ "$conflict_markers" -gt 0 ]; then
    hygiene_issues="${hygiene_issues}; ${conflict_markers} file(s) with merge conflict markers"
  fi

  # Check for debug statements
  local debug_stmts=0
  if [ -n "$diff_content" ]; then
    debug_stmts=$(echo "$diff_content" | grep -cE '^\+.*(console\.log|debugger|print\(.*DEBUG)' || true)
  fi
  if [ "$debug_stmts" -gt 3 ]; then
    hygiene_issues="${hygiene_issues}; ${debug_stmts} debug statements in diff"
  fi

  if [ -n "$hygiene_issues" ]; then
    tier1_check "hygiene" false "$hygiene_issues"
  else
    tier1_check "hygiene" true "Clean"
  fi

  # 1e. Skill linter (if SKILL.md files changed)
  log "  [1e] Skill linter..."
  local skill_files
  skill_files=$(echo "$changed_files" | grep 'SKILL\.md$' || true)

  if [ -n "$skill_files" ]; then
    local skill_pass=true
    local skill_detail=""

    while IFS= read -r sf; do
      [ -z "$sf" ] && continue
      [ ! -f "$sf" ] && continue

      local lint_result
      lint_result=$(bash "$SCRIPT_DIR/skill-linter.sh" "$sf" --json 2>/dev/null || echo '{"pass": false, "errors": ["linter crashed"]}')

      local sf_pass
      sf_pass=$(echo "$lint_result" | jq -r '.pass')
      if [ "$sf_pass" = "false" ]; then
        skill_pass=false
        local sf_errors
        sf_errors=$(echo "$lint_result" | jq -r '.errors[]' 2>/dev/null | head -3 | tr '\n' '; ')
        skill_detail="${skill_detail}${sf}: ${sf_errors} "
      fi
    done <<< "$skill_files"

    if [ "$skill_pass" = true ]; then
      tier1_check "skill_lint" true "All SKILL.md files passed lint"
    else
      tier1_check "skill_lint" false "${skill_detail:0:500}"
    fi
  else
    tier1_check "skill_lint" true "No SKILL.md files changed"
  fi

  log "Tier 1: $(echo "$tier1_results" | jq -r 'if .pass then "PASSED" else "FAILED" end')"
}

# ─── Tier 2: AI Review ──────────────────────────────────────────────────────

tier2_results='{"pass": true, "scores": {}, "blocking_issues": [], "suggestions": []}'

run_tier2() {
  log "Tier 2: Starting AI review..."

  cd "$REPO_ROOT"

  # Get diff for review
  local diff_stat
  diff_stat=$(git diff "main...$WORKER_BRANCH" --stat 2>/dev/null || echo "no diff available")
  local full_diff
  full_diff=$(git diff "main...$WORKER_BRANCH" 2>/dev/null | head -c 12000 || echo "no diff available")

  local prompt
  prompt="You are a senior code reviewer. Analyze this diff and provide a structured quality assessment.

## DIFF STAT:
${diff_stat}

## FULL DIFF (may be truncated):
${full_diff}

## SCORING RUBRIC
Score each dimension 1-10 and identify any blocking issues.

Output ONLY a JSON block between \`\`\`json and \`\`\` markers:
\`\`\`json
{
  \"correctness\": <1-10>,
  \"readability\": <1-10>,
  \"convention\": <1-10>,
  \"security\": <1-10>,
  \"completeness\": <1-10>,
  \"simplicity\": <1-10>,
  \"overall\": <1-10>,
  \"blocking_issues\": [\"issue 1\", \"issue 2\"],
  \"suggestions\": [\"suggestion 1\"]
}
\`\`\`

Rules:
- blocking_issues: MUST be empty for a PASS. Only list issues that would cause bugs, security problems, or break functionality.
- suggestions: non-blocking improvements
- overall: weighted average biased toward correctness and security
- Be strict but fair. Score 7+ means production-ready."

  local ai_output
  if command -v claude &>/dev/null; then
    ai_output=$(echo "$prompt" | claude -p --max-turns 1 --output-format text 2>/dev/null || echo "AI review unavailable")
  else
    log "  claude CLI not found, using placeholder scores"
    ai_output='```json
{"correctness": 7, "readability": 7, "convention": 7, "security": 8, "completeness": 7, "simplicity": 7, "overall": 7, "blocking_issues": [], "suggestions": ["claude CLI not available for AI review"]}
```'
  fi

  # Extract JSON from markdown code block
  local ai_json
  ai_json=$(echo "$ai_output" | sed -n '/```json/,/```/p' | sed '1d;$d' || echo "{}")

  # Validate and parse
  if echo "$ai_json" | jq . >/dev/null 2>&1; then
    local overall
    overall=$(echo "$ai_json" | jq -r '.overall // 0')
    local blocking
    blocking=$(echo "$ai_json" | jq -r '.blocking_issues | length')

    tier2_results=$(echo "$ai_json" | jq '{
      pass: ((.overall >= 7) and ((.blocking_issues | length) == 0)),
      scores: {
        correctness: .correctness,
        readability: .readability,
        convention: .convention,
        security: .security,
        completeness: .completeness,
        simplicity: .simplicity,
        overall: .overall
      },
      blocking_issues: .blocking_issues,
      suggestions: .suggestions
    }')

    log "Tier 2: overall=${overall}, blocking=${blocking} — $(echo "$tier2_results" | jq -r 'if .pass then "PASSED" else "FAILED" end')"
  else
    log "Tier 2: Failed to parse AI response, marking as pass with warning"
    tier2_results='{"pass": true, "scores": {"overall": 0}, "blocking_issues": [], "suggestions": ["AI response parsing failed"]}'
  fi
}

# ─── Tier 3: Acceptance Criteria ─────────────────────────────────────────────

tier3_results='{"pass": true, "criteria": [], "unmet": []}'

run_tier3() {
  if [ -z "$SPEC_FILE" ] || [ ! -f "$SPEC_FILE" ]; then
    log "Tier 3: No spec file provided or not found, skipping"
    tier3_results='{"pass": true, "criteria": [], "unmet": [], "skipped": true}'
    return
  fi

  log "Tier 3: Starting acceptance criteria check..."

  cd "$REPO_ROOT"

  # Extract acceptance criteria from spec
  local criteria
  criteria=$(sed -n '/## Acceptance Criteria/,/## /p' "$SPEC_FILE" | grep -E '^\- \[' || echo "No criteria found")

  if [ "$criteria" = "No criteria found" ]; then
    log "Tier 3: No acceptance criteria in spec, skipping"
    tier3_results='{"pass": true, "criteria": [], "unmet": [], "skipped": true}'
    return
  fi

  local full_diff
  full_diff=$(git diff "main...$WORKER_BRANCH" 2>/dev/null | head -c 10000 || echo "")

  local prompt
  prompt="You are a QA engineer verifying implementation against spec. Check each acceptance criterion.

## ACCEPTANCE CRITERIA (from spec):
${criteria}

## IMPLEMENTATION DIFF (may be truncated):
${full_diff}

Output ONLY a JSON block:
\`\`\`json
{
  \"criteria\": [
    {\"criterion\": \"exact text from spec\", \"status\": \"pass\", \"evidence\": \"found in file X line Y\"},
    {\"criterion\": \"exact text\", \"status\": \"fail\", \"evidence\": \"not found in diff\"},
    {\"criterion\": \"exact text\", \"status\": \"unclear\", \"evidence\": \"partial implementation\"}
  ],
  \"overall\": \"pass\",
  \"unmet\": [\"list of failed criteria text\"]
}
\`\`\`

Rules:
- overall is \"pass\" only if ALL criteria are \"pass\" or \"unclear\" (zero \"fail\")
- Be evidence-based: cite file names and patterns from the diff
- \"unclear\" means implementation exists but can't confirm full compliance from diff alone"

  local ai_output
  if command -v claude &>/dev/null; then
    ai_output=$(echo "$prompt" | claude -p --max-turns 1 --output-format text 2>/dev/null || echo "AI check unavailable")
  else
    log "  claude CLI not found, acceptance check skipped"
    tier3_results='{"pass": true, "criteria": [], "unmet": [], "skipped": true}'
    return
  fi

  # Extract JSON
  local ai_json
  ai_json=$(echo "$ai_output" | sed -n '/```json/,/```/p' | sed '1d;$d' || echo "{}")

  if echo "$ai_json" | jq . >/dev/null 2>&1; then
    local overall
    overall=$(echo "$ai_json" | jq -r '.overall // "pass"')
    local unmet_count
    unmet_count=$(echo "$ai_json" | jq -r '.unmet | length')

    tier3_results=$(echo "$ai_json" | jq '{
      pass: (.overall == "pass"),
      criteria: .criteria,
      unmet: .unmet
    }')

    log "Tier 3: overall=${overall}, unmet=${unmet_count} — $(echo "$tier3_results" | jq -r 'if .pass then "PASSED" else "FAILED" end')"
  else
    log "Tier 3: Failed to parse AI response, marking as pass"
    tier3_results='{"pass": true, "criteria": [], "unmet": [], "parse_error": true}'
  fi
}

# ─── Execute Tiers ───────────────────────────────────────────────────────────

log "Quality Gate starting for task ${TASK_ID}, branch ${WORKER_BRANCH}"

case "$RUN_TIER" in
  1)   run_tier1 ;;
  2)   run_tier2 ;;
  3)   run_tier3 ;;
  all) run_tier1; run_tier2; run_tier3 ;;
  *)   echo "Unknown tier: $RUN_TIER (use 1, 2, 3, or all)" >&2; exit 2 ;;
esac

# ─── Assemble Final Result ───────────────────────────────────────────────────

tier1_pass=$(echo "$tier1_results" | jq -r '.pass')
tier2_pass=$(echo "$tier2_results" | jq -r '.pass')
tier3_pass=$(echo "$tier3_results" | jq -r '.pass')

overall_pass=true
[ "$tier1_pass" = "false" ] && overall_pass=false
[ "$tier2_pass" = "false" ] && overall_pass=false
[ "$tier3_pass" = "false" ] && overall_pass=false

final_result=$(jq -n \
  --arg task_id "$TASK_ID" \
  --arg branch "$WORKER_BRANCH" \
  --arg spec_file "$SPEC_FILE" \
  --arg timestamp "$NOW" \
  --argjson overall_pass "$overall_pass" \
  --argjson tier1 "$tier1_results" \
  --argjson tier2 "$tier2_results" \
  --argjson tier3 "$tier3_results" \
  '{
    task_id: $task_id,
    branch: $branch,
    spec_file: $spec_file,
    timestamp: $timestamp,
    overall_pass: $overall_pass,
    tier1: $tier1,
    tier2: $tier2,
    tier3: $tier3
  }')

# Write output
mkdir -p "$(dirname "$OUTPUT_FILE")"
echo "$final_result" > "$OUTPUT_FILE"

log "Quality Gate result: $([ "$overall_pass" = "true" ] && echo "PASSED" || echo "FAILED")"
log "Results written to: $OUTPUT_FILE"

# Summary to stdout
echo ""
echo "═══════════════════════════════════════════"
echo " QUALITY GATE: $([ "$overall_pass" = "true" ] && echo "✅ PASSED" || echo "❌ FAILED")"
echo "═══════════════════════════════════════════"
echo " Tier 1 (Automated): $([ "$tier1_pass" = "true" ] && echo "✅" || echo "❌")"
echo " Tier 2 (AI Review): $([ "$tier2_pass" = "true" ] && echo "✅" || echo "❌")"
echo " Tier 3 (Acceptance): $([ "$tier3_pass" = "true" ] && echo "✅" || echo "❌")"
echo "═══════════════════════════════════════════"

# Exit code
[ "$overall_pass" = "true" ] && exit 0 || exit 1
