#!/bin/bash
# Feedback Synthesizer — Generates structured correction feedback from gate failures
#
# Usage: feedback-synthesizer.sh <task-id> <round> <gate-results-file> [--output <feedback-file>]
#
# Reads quality gate results JSON and produces a human-readable markdown document
# that tells the worker EXACTLY what to fix. The feedback is designed to be
# included in the correction task description.
#
# Output: .worktree-shared/feedback/<task-id>-round-<N>.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"

# ─── Args ────────────────────────────────────────────────────────────────────

TASK_ID=""
ROUND=""
GATE_RESULTS=""
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: feedback-synthesizer.sh <task-id> <round> <gate-results-file> [--output <file>]"
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *)
      if [ -z "$TASK_ID" ]; then TASK_ID="$1"
      elif [ -z "$ROUND" ]; then ROUND="$1"
      elif [ -z "$GATE_RESULTS" ]; then GATE_RESULTS="$1"
      else echo "Unexpected arg: $1" >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$TASK_ID" ] || [ -z "$ROUND" ] || [ -z "$GATE_RESULTS" ]; then
  echo "Error: task-id, round, and gate-results-file required" >&2
  exit 2
fi

if [ ! -f "$GATE_RESULTS" ]; then
  echo "Error: gate results file not found: $GATE_RESULTS" >&2
  exit 2
fi

# Default output
if [ -z "$OUTPUT_FILE" ]; then
  mkdir -p "$SHARED_DIR/feedback"
  OUTPUT_FILE="$SHARED_DIR/feedback/${TASK_ID}-round-${ROUND}.md"
fi

MAX_ROUNDS=3
REMAINING=$((MAX_ROUNDS - ROUND))

# ─── Parse Gate Results ──────────────────────────────────────────────────────

BRANCH=$(jq -r '.branch // "unknown"' "$GATE_RESULTS")
TIMESTAMP=$(jq -r '.timestamp // "unknown"' "$GATE_RESULTS")

# Tier 1 results
T1_PASS=$(jq -r '.tier1.pass' "$GATE_RESULTS")
T1_CHECKS=$(jq -r '.tier1.checks // {}' "$GATE_RESULTS")

# Tier 2 results
T2_PASS=$(jq -r '.tier2.pass' "$GATE_RESULTS")
T2_OVERALL=$(jq -r '.tier2.scores.overall // 0' "$GATE_RESULTS")
T2_BLOCKING=$(jq -r '.tier2.blocking_issues // []' "$GATE_RESULTS")
T2_SUGGESTIONS=$(jq -r '.tier2.suggestions // []' "$GATE_RESULTS")
T2_SCORES=$(jq -r '.tier2.scores // {}' "$GATE_RESULTS")

# Tier 3 results
T3_PASS=$(jq -r '.tier3.pass' "$GATE_RESULTS")
T3_UNMET=$(jq -r '.tier3.unmet // []' "$GATE_RESULTS")
T3_CRITERIA=$(jq -r '.tier3.criteria // []' "$GATE_RESULTS")

# ─── Generate Feedback Document ──────────────────────────────────────────────

{
  echo "# Correction Feedback: ${TASK_ID} (Round ${ROUND}/${MAX_ROUNDS})"
  echo ""
  echo "**Branch**: \`${BRANCH}\`"
  echo "**Gate Run**: ${TIMESTAMP}"
  echo "**Rounds Remaining**: ${REMAINING}"
  echo ""

  # ── What Passed ──
  echo "## What Passed"
  echo ""

  # Tier 1 checks
  echo "$T1_CHECKS" | jq -r 'to_entries[] | select(.value.pass == true) | "- [x] \(.key): \(.value.detail)"'

  # Tier-level passes
  [ "$T1_PASS" = "true" ] && echo "- [x] **Tier 1** (Automated): All checks passed"
  [ "$T2_PASS" = "true" ] && echo "- [x] **Tier 2** (AI Review): Score ${T2_OVERALL}/10"
  [ "$T3_PASS" = "true" ] && echo "- [x] **Tier 3** (Acceptance): All criteria met"

  echo ""

  # ── What Failed ──
  echo "## What Failed (BLOCKING — must fix)"
  echo ""

  HAVE_FAILURES=false

  # Tier 1 failures
  T1_FAIL_COUNT=$(echo "$T1_CHECKS" | jq '[to_entries[] | select(.value.pass == false)] | length')
  if [ "$T1_FAIL_COUNT" -gt 0 ]; then
    HAVE_FAILURES=true
    echo "### Tier 1: Automated Checks"
    echo ""
    echo "$T1_CHECKS" | jq -r 'to_entries[] | select(.value.pass == false) | "- **\(.key)**: \(.value.detail)"'
    echo ""
  fi

  # Tier 2 failures
  T2_BLOCKING_COUNT=$(echo "$T2_BLOCKING" | jq 'length')
  if [ "$T2_PASS" = "false" ]; then
    HAVE_FAILURES=true
    echo "### Tier 2: AI Code Review (Score: ${T2_OVERALL}/10)"
    echo ""

    # Show dimension scores
    echo "| Dimension | Score |"
    echo "|-----------|-------|"
    echo "$T2_SCORES" | jq -r 'to_entries[] | select(.key != "overall") | "| \(.key) | \(.value)/10 |"'
    echo ""

    # Blocking issues
    if [ "$T2_BLOCKING_COUNT" -gt 0 ]; then
      echo "**Blocking Issues (must fix):**"
      echo "$T2_BLOCKING" | jq -r '.[] | "1. \(.)"'
      echo ""
    fi

    # Overall too low
    if [ "$(echo "$T2_OVERALL < 7" | bc 2>/dev/null || echo 1)" = "1" ]; then
      echo "**Overall score ${T2_OVERALL}/10 is below threshold (7).** Improve readability, convention adherence, and simplicity."
      echo ""
    fi
  fi

  # Tier 3 failures
  T3_UNMET_COUNT=$(echo "$T3_UNMET" | jq 'length')
  if [ "$T3_PASS" = "false" ]; then
    HAVE_FAILURES=true
    echo "### Tier 3: Acceptance Criteria"
    echo ""

    # Show all criteria with status
    T3_CRITERIA_COUNT=$(echo "$T3_CRITERIA" | jq 'length')
    if [ "$T3_CRITERIA_COUNT" -gt 0 ]; then
      echo "$T3_CRITERIA" | jq -r '.[] |
        if .status == "pass" then "- [x] \(.criterion)"
        elif .status == "fail" then "- [ ] **FAILED**: \(.criterion)\n  - Evidence: \(.evidence)"
        else "- [~] \(.criterion) (unclear: \(.evidence))"
        end'
      echo ""
    fi

    if [ "$T3_UNMET_COUNT" -gt 0 ]; then
      echo "**Unmet criteria:**"
      echo "$T3_UNMET" | jq -r '.[] | "- \(.)"'
      echo ""
    fi
  fi

  if [ "$HAVE_FAILURES" = false ]; then
    echo "_No blocking failures found. This feedback should not have been generated._"
    echo ""
  fi

  # ── Suggestions (non-blocking) ──
  T2_SUGGESTION_COUNT=$(echo "$T2_SUGGESTIONS" | jq 'length')
  if [ "$T2_SUGGESTION_COUNT" -gt 0 ]; then
    echo "## Suggestions (non-blocking, nice to have)"
    echo ""
    echo "$T2_SUGGESTIONS" | jq -r '.[] | "- \(.)"'
    echo ""
  fi

  # ── Action Required ──
  echo "## Action Required"
  echo ""
  echo "1. Fix **ALL** items listed in \"What Failed\" above"
  echo "2. Do NOT add new features or refactor unrelated code"
  echo "3. Run verification before marking task complete:"
  echo "   - \`npx tsc --noEmit\` (if TypeScript files changed)"
  echo "   - \`npm run build\`"
  echo "4. Commit with message: \`fix(correction-r${ROUND}): <summary of fixes>\`"
  echo ""
  echo "Quality gates will run again after completion. ${REMAINING} round(s) remaining before escalation to human."

} > "$OUTPUT_FILE"

echo "Feedback written to: $OUTPUT_FILE"
