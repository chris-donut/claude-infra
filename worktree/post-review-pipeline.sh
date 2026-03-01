#!/bin/bash
# Post-Review Pipeline — Closed-loop design automation
# Runs 5 stages after a code review completes:
#   1. Retrospective   — analyze spec vs implementation
#   2. Automation       — score templateability, draft skill if >= 7
#   3. Consumer Routing — auto-create PR, notify consumer
#   4. Loop Review      — meta-analyze entire cycle
#   5. Improvement      — draft updates to rules/templates
#
# Usage: post-review-pipeline.sh <task-slug> [--dry-run]
#
# Called automatically by orchestrator.sh when a "review:" task completes.
# Can also be run manually for any completed task.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARED_DIR="$REPO_ROOT/.worktree-shared"
STATE_DIR="$REPO_ROOT/state"
SKILLS_DIR="${SKILLS_DIR:-$REPO_ROOT/donut-product/skills}"
RETRO_DIR="$SHARED_DIR/retrospectives"
LOOP_DIR="$SHARED_DIR/loop-reviews"
IMPROVE_DIR="$SHARED_DIR/improvements"
DRAFTS_DIR="$SKILLS_DIR/drafts"
CANDIDATES_FILE="$STATE_DIR/automation-candidates.json"

# Parse args
SLUG=""
DRY_RUN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: post-review-pipeline.sh <task-slug> [--dry-run]"
      echo ""
      echo "Runs the 5-stage post-review closed-loop pipeline:"
      echo "  1. Retrospective     — spec vs implementation analysis"
      echo "  2. Automation        — score templateability (draft skill if >= 7)"
      echo "  3. Consumer Routing  — auto-create PR"
      echo "  4. Loop Review       — meta-analyze entire cycle"
      echo "  5. Improvement       — draft updates to rules/templates"
      echo ""
      echo "Options:"
      echo "  --dry-run    Generate placeholder outputs without Claude calls"
      exit 0
      ;;
    -*) echo "Unknown flag: $1"; exit 1 ;;
    *) SLUG="$1"; shift ;;
  esac
done

if [ -z "$SLUG" ]; then
  echo "Error: task slug required"
  echo "Usage: post-review-pipeline.sh <task-slug> [--dry-run]"
  exit 1
fi

# Ensure directories exist
mkdir -p "$RETRO_DIR" "$LOOP_DIR" "$IMPROVE_DIR" "$DRAFTS_DIR" "$STATE_DIR"

# Init candidates file if missing
if [ ! -f "$CANDIDATES_FILE" ]; then
  echo '{"version":1,"candidates":[]}' > "$CANDIDATES_FILE"
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TODAY="$(date +%Y-%m-%d)"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [pipeline:$SLUG] $*"
}

notify_telegram() {
  local message="$1"
  local token="${TELEGRAM_BOT_TOKEN:-}"
  local chat_id="${TELEGRAM_CHAT_ID:-}"
  if [ -z "$token" ] || [ -z "$chat_id" ]; then return 0; fi
  local payload
  payload="$(jq -n --arg chat_id "$chat_id" --arg text "$message" \
    '{chat_id: $chat_id, text: $text, parse_mode: "Markdown"}')"

  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    > /dev/null 2>&1 || true
}

# Find the spec file for this slug
find_spec_file() {
  local spec_file=""
  spec_file="$(ls -1 "$REPO_ROOT"/docs/plans/*-"$SLUG"-spec.md 2>/dev/null | head -1 || true)"
  echo "${spec_file:-}"
}

# Find the worker branch for this slug (search task queue)
find_worker_info() {
  local tasks_file="$SHARED_DIR/dev-tasks.json"
  if [ ! -f "$tasks_file" ]; then
    echo ""
    return 0
  fi

  # Find the original implementation task (not the review task)
  jq -r --arg slug "$SLUG" \
    '.tasks[] | select(.title == $slug and .status == "completed" and .result == "success") | .claimed_by' \
    "$tasks_file" 2>/dev/null | head -1 || echo ""
}

# Run a lightweight Claude analysis (max 3 turns, ~30s)
run_claude_analysis() {
  local prompt="$1"
  local output_file="$2"

  if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Would invoke Claude for: $(echo "$prompt" | head -1)"
    cat > "$output_file" <<EOF
# [DRY RUN] Analysis for: $SLUG
Generated at: $NOW
This is a placeholder. Run without --dry-run for real analysis.
EOF
    return 0
  fi

  # Use claude CLI for lightweight one-shot analysis
  # --print outputs to stdout, --max-turns 3 keeps it short
  if command -v claude &>/dev/null; then
    claude -p "$prompt" --max-turns 3 --output-format text 2>/dev/null > "$output_file" || {
      log "WARN: Claude analysis failed, writing fallback"
      echo "# Analysis failed for: $SLUG" > "$output_file"
      echo "Claude invocation failed at $NOW. Run manually." >> "$output_file"
    }
  else
    log "WARN: claude CLI not found, writing placeholder"
    echo "# Claude CLI not available" > "$output_file"
    echo "Install claude CLI to enable AI-powered analysis." >> "$output_file"
  fi
}

# ─────────────────────────────────────────────────────────────
# STAGE 1: RETROSPECTIVE
# ─────────────────────────────────────────────────────────────
stage_retrospective() {
  log "Stage 1/5: Retrospective"

  local spec_file
  spec_file="$(find_spec_file)"
  local spec_content=""
  if [ -n "$spec_file" ] && [ -f "$spec_file" ]; then
    spec_content="$(cat "$spec_file")"
  else
    spec_content="[Spec file not found for slug: $SLUG]"
  fi

  local worker_id
  worker_id="$(find_worker_info)"
  local worker_branch="${worker_id:+${worker_id/worker-/worker/}}"

  # Get implementation diff (worker branch vs main)
  local diff_content=""
  if [ -n "$worker_branch" ]; then
    diff_content="$(git -C "$REPO_ROOT" diff "main...$worker_branch" --stat 2>/dev/null || echo '[diff unavailable]')"
  fi

  # Get review task info
  local review_findings=""
  review_findings="$(jq -r --arg slug "review: $SLUG" \
    '.tasks[] | select(.title == $slug) | .reason // "No review notes recorded"' \
    "$SHARED_DIR/dev-tasks.json" 2>/dev/null || echo "[review data unavailable]")"

  local output_file="$RETRO_DIR/$SLUG.md"

  local prompt="You are a retrospective analyst for a software development pipeline. Analyze this completed task and provide a structured retrospective.

## TASK: $SLUG

## SPEC:
$spec_content

## IMPLEMENTATION DIFF (stat):
$diff_content

## REVIEW FINDINGS:
$review_findings

## ANALYSIS REQUIRED:
Provide a markdown document with these sections:

### Design Decisions
What design decisions were made during implementation? Were they good choices?

### Spec Quality
Was the spec sufficient, ambiguous, or over-specified? What was missing?

### Patterns
What patterns emerged that could be reused in future tasks?

### Execution Quality
Rate spec compliance (1-10). Did the implementation match what was asked?

### Recommendations
What should be done differently next time for a similar task?

Keep the analysis concise (under 300 words). Focus on actionable insights."

  run_claude_analysis "$prompt" "$output_file"
  log "Retrospective written to: $output_file"
}

# ─────────────────────────────────────────────────────────────
# STAGE 2: AUTOMATION ASSESSMENT
# ─────────────────────────────────────────────────────────────
stage_automation() {
  log "Stage 2/5: Automation Assessment"

  local retro_content=""
  [ -f "$RETRO_DIR/$SLUG.md" ] && retro_content="$(cat "$RETRO_DIR/$SLUG.md")"

  # Get existing automation candidates for comparison
  local existing_candidates=""
  existing_candidates="$(jq -r '.candidates[] | "- \(.slug) (score: \(.score))"' "$CANDIDATES_FILE" 2>/dev/null || echo "none")"

  # List existing skills
  local existing_skills=""
  existing_skills="$(ls -1 "$SKILLS_DIR"/*/SKILL.md 2>/dev/null | sed 's|.*/skills/||;s|/SKILL.md||' | tr '\n' ', ' || echo "none")"

  local output_file="$SHARED_DIR/automation-assessment-$SLUG.md"

  local prompt="You are an automation assessment agent. Evaluate whether this completed task could be automated as a reusable skill.

## TASK: $SLUG

## RETROSPECTIVE:
$retro_content

## EXISTING AUTOMATION CANDIDATES:
$existing_candidates

## EXISTING SKILLS:
$existing_skills

## ASSESSMENT REQUIRED:
Output a JSON block (wrapped in \`\`\`json ... \`\`\`) with exactly these fields:
{
  \"score\": <1-10 integer>,
  \"similarity\": [\"list\", \"of\", \"similar\", \"tasks\"],
  \"templateable_parts\": \"description of what could be templated\",
  \"non_templateable_parts\": \"description of what requires human judgment\",
  \"roi_estimate\": \"how much time would automation save per occurrence\",
  \"recommended_skill_name\": \"suggested-skill-name or null if score < 7\"
}

Then provide a brief (100 word) rationale for the score.

Scoring guide:
- 1-3: Unique, requires heavy human judgment
- 4-6: Some repeatable elements but significant variation
- 7-8: Mostly templateable, worth creating a skill
- 9-10: Almost identical to previous tasks, should definitely be automated"

  run_claude_analysis "$prompt" "$output_file"

  # Extract score from the assessment (parse JSON block — macOS compatible)
  local score=0
  if [ -f "$output_file" ]; then
    # Extract JSON block between ```json and ```, then parse with jq
    local json_block=""
    json_block="$(sed -n '/```json/,/```/p' "$output_file" | sed '1d;$d' 2>/dev/null || true)"
    if [ -n "$json_block" ]; then
      score="$(echo "$json_block" | jq -r '.score // 0' 2>/dev/null || echo 0)"
    fi
  fi

  # Update automation candidates
  local similar_json="[]"
  if [ -n "$json_block" ]; then
    similar_json="$(echo "$json_block" | jq -c '.similarity // []' 2>/dev/null || echo '[]')"
  fi

  local skill_name=""
  if [ -n "$json_block" ]; then
    skill_name="$(echo "$json_block" | jq -r '.recommended_skill_name // empty' 2>/dev/null || echo "")"
  fi

  local draft_path=""
  if [ "$score" -ge 7 ] && [ -n "$skill_name" ] && [ "$skill_name" != "null" ]; then
    draft_path="donut-product/skills/drafts/$skill_name/SKILL.md"
    stage_draft_skill "$skill_name" "$output_file"
  fi

  # Append to candidates file
  local candidate_json
  candidate_json="$(jq -n \
    --arg slug "$SLUG" \
    --argjson score "$score" \
    --arg assessed_at "$NOW" \
    --argjson similar "$similar_json" \
    --arg draft_path "$draft_path" \
    '{
      slug: $slug,
      score: $score,
      assessed_at: $assessed_at,
      similar_to: $similar,
      draft_skill_path: $draft_path,
      status: (if $score >= 7 then "draft" else "assessed" end)
    }'
  )"

  # Atomic update
  local tmp
  tmp="$(mktemp)"
  jq --argjson candidate "$candidate_json" '.candidates += [$candidate]' "$CANDIDATES_FILE" > "$tmp" && mv "$tmp" "$CANDIDATES_FILE"

  log "Automation score: $score/10"

  if [ "$score" -ge 7 ]; then
    notify_telegram "🤖 *Automation Candidate*
Task: $SLUG
Score: $score/10
Draft skill: \`$skill_name\`
Review and approve to activate."
  fi
}

# Helper: Generate a draft skill from automation assessment
stage_draft_skill() {
  local skill_name="$1"
  local assessment_file="$2"

  log "Drafting skill: $skill_name"

  local draft_dir="$DRAFTS_DIR/$skill_name"
  mkdir -p "$draft_dir"

  local spec_content=""
  local spec_file
  spec_file="$(find_spec_file)"
  [ -n "$spec_file" ] && [ -f "$spec_file" ] && spec_content="$(cat "$spec_file")"

  local assessment_content=""
  [ -f "$assessment_file" ] && assessment_content="$(cat "$assessment_file")"

  local output_file="$draft_dir/SKILL.md"

  local prompt="You are a skill author for Claude Code. Generate a SKILL.md file that automates this type of task.

## ORIGINAL TASK: $SLUG

## SPEC THAT WAS USED:
$spec_content

## AUTOMATION ASSESSMENT:
$assessment_content

## GENERATE:
A complete SKILL.md file with:
1. YAML frontmatter (description field)
2. Clear trigger conditions (when should this skill be invoked?)
3. Step-by-step execution sequence
4. Input parameters (what varies between invocations)
5. Output format
6. Error handling

The skill should be generic enough to handle similar future tasks, not specific to this one instance.
Keep it under 200 lines. Follow the pattern of existing skills in this project."

  run_claude_analysis "$prompt" "$output_file"
  log "Draft skill written to: $output_file"
}

# ─────────────────────────────────────────────────────────────
# STAGE 3: CONSUMER ROUTING
# ─────────────────────────────────────────────────────────────
stage_consumer_routing() {
  log "Stage 3/5: Consumer Routing"

  local worker_id
  worker_id="$(find_worker_info)"

  if [ -z "$worker_id" ]; then
    log "WARN: No worker info found for $SLUG, skipping PR creation"
    return 0
  fi

  local worker_branch="${worker_id/worker-/worker/}"

  # Read spec for PR body
  local spec_file
  spec_file="$(find_spec_file)"
  local spec_summary=""
  if [ -n "$spec_file" ] && [ -f "$spec_file" ]; then
    # Extract "What to Build" section
    spec_summary="$(sed -n '/## What to Build/,/## /p' "$spec_file" | head -10)"
  fi

  # Read automation score
  local auto_score="N/A"
  auto_score="$(jq -r --arg slug "$SLUG" \
    '[.candidates[] | select(.slug == $slug) | .score] | last // "N/A"' \
    "$CANDIDATES_FILE" 2>/dev/null || echo "N/A")"

  # Read retrospective summary (first 5 lines after header)
  local retro_summary=""
  [ -f "$RETRO_DIR/$SLUG.md" ] && retro_summary="$(head -20 "$RETRO_DIR/$SLUG.md")"

  if [ "$DRY_RUN" = true ]; then
    log "[DRY-RUN] Would create PR from $worker_branch to main"
    log "[DRY-RUN] Title: feat($SLUG): implementation"
    return 0
  fi

  # Create PR using gh CLI
  if command -v gh &>/dev/null; then
    local pr_url
    pr_url="$(gh pr create \
      --base main \
      --head "$worker_branch" \
      --title "feat($SLUG): implementation" \
      --body "$(cat <<EOF
## Summary
Dispatched via \`/go\`, implemented by $worker_id.

$spec_summary

## Automation Score: $auto_score/10

## Retrospective
$retro_summary

---
📊 Generated by post-review-pipeline
EOF
)" 2>&1)" || {
      log "WARN: PR creation failed: $pr_url"
      # PR might already exist or branch not pushed
      pr_url="(PR creation failed — branch may need push)"
    }

    log "PR: $pr_url"
    notify_telegram "🔗 *PR Created*
Task: $SLUG
$pr_url"
  else
    log "WARN: gh CLI not found, skipping PR creation"
  fi
}

# ─────────────────────────────────────────────────────────────
# STAGE 4: LOOP REVIEW
# ─────────────────────────────────────────────────────────────
stage_loop_review() {
  log "Stage 4/5: Loop Review"

  # Gather all pipeline artifacts
  local spec_content=""
  local spec_file
  spec_file="$(find_spec_file)"
  [ -n "$spec_file" ] && [ -f "$spec_file" ] && spec_content="$(cat "$spec_file")"

  local retro_content=""
  [ -f "$RETRO_DIR/$SLUG.md" ] && retro_content="$(cat "$RETRO_DIR/$SLUG.md")"

  local auto_content=""
  [ -f "$SHARED_DIR/automation-assessment-$SLUG.md" ] && auto_content="$(cat "$SHARED_DIR/automation-assessment-$SLUG.md")"

  # Get task timestamps for duration analysis
  local task_data=""
  task_data="$(jq -c --arg slug "$SLUG" \
    '.tasks[] | select(.title == $slug and .status == "completed")' \
    "$SHARED_DIR/dev-tasks.json" 2>/dev/null | head -1 || echo '{}')"

  local output_file="$LOOP_DIR/$SLUG.md"

  local prompt="You are a pipeline efficiency analyst. Review the entire /go dispatch cycle for this task.

## TASK: $SLUG

## SPEC:
$spec_content

## RETROSPECTIVE:
$retro_content

## AUTOMATION ASSESSMENT:
$auto_content

## TASK METADATA:
$task_data

## META-ANALYSIS REQUIRED:
Provide a markdown document with:

### Pipeline Efficiency (rate 1-10)
Was /go the right dispatch mechanism? Was the spec detailed enough? Did the worker need more/less guidance?

### Bottlenecks
Where did the pipeline slow down? Spec quality? Worker confusion? Review overhead?

### Dispatch Appropriateness
Should this have been: (a) /go dispatch, (b) manual implementation, (c) existing skill, (d) not done at all?

### Recommendations
Top 3 concrete improvements to the pipeline for next time.

Keep under 200 words. Be brutally honest."

  run_claude_analysis "$prompt" "$output_file"
  log "Loop review written to: $output_file"
}

# ─────────────────────────────────────────────────────────────
# STAGE 5: IMPROVEMENT ACTION
# ─────────────────────────────────────────────────────────────
stage_improvement() {
  log "Stage 5/5: Improvement Action"

  local loop_review=""
  [ -f "$LOOP_DIR/$SLUG.md" ] && loop_review="$(cat "$LOOP_DIR/$SLUG.md")"

  local retro_content=""
  [ -f "$RETRO_DIR/$SLUG.md" ] && retro_content="$(cat "$RETRO_DIR/$SLUG.md")"

  # Read current go command template (first 50 lines for context)
  local go_template=""
  [ -f "$HOME/.claude/commands/go.md" ] && go_template="$(head -50 "$HOME/.claude/commands/go.md")"

  local output_file="$IMPROVE_DIR/$SLUG.md"

  local prompt="You are an improvement agent for a development pipeline. Based on this loop review, draft concrete improvements.

## TASK: $SLUG

## LOOP REVIEW:
$loop_review

## RETROSPECTIVE:
$retro_content

## CURRENT /GO TEMPLATE (first 50 lines):
$go_template

## GENERATE IMPROVEMENTS:
For each improvement, output a section with:

### Improvement 1: <title>
- **Target file**: <path to file that should be modified>
- **What to change**: <specific description>
- **Why**: <rationale from loop review>
- **Draft diff** (if applicable):
\`\`\`diff
- old line
+ new line
\`\`\`

Only suggest improvements that are:
1. Concrete (specific file + specific change)
2. Based on evidence from this task's review
3. Generalizable (not specific to this one task)

Maximum 3 improvements. Skip if nothing meaningful to suggest."

  run_claude_analysis "$prompt" "$output_file"
  log "Improvements written to: $output_file"
}

# ─────────────────────────────────────────────────────────────
# FINAL: TELEGRAM SUMMARY
# ─────────────────────────────────────────────────────────────
send_loop_summary() {
  log "Sending loop summary"

  local auto_score="N/A"
  auto_score="$(jq -r --arg slug "$SLUG" \
    '[.candidates[] | select(.slug == $slug) | .score] | last // "N/A"' \
    "$CANDIDATES_FILE" 2>/dev/null || echo "N/A")"

  local worker_id
  worker_id="$(find_worker_info)"
  worker_id="${worker_id:-unknown}"

  # Count improvements suggested
  local improve_count=0
  if [ -f "$IMPROVE_DIR/$SLUG.md" ]; then
    improve_count="$(grep -c '### Improvement' "$IMPROVE_DIR/$SLUG.md" || true)"
    improve_count="${improve_count:-0}"
  fi

  local draft_skill=""
  draft_skill="$(jq -r --arg slug "$SLUG" \
    '[.candidates[] | select(.slug == $slug and .draft_skill_path != "") | .draft_skill_path] | last // ""' \
    "$CANDIDATES_FILE" 2>/dev/null || echo "")"

  local auto_line="Automation: ${auto_score}/10"
  [ -n "$draft_skill" ] && auto_line="$auto_line — draft skill created"

  notify_telegram "📊 *Loop Complete*: $SLUG
├ Implementation: ✅ by $worker_id
├ Review: ✅
├ $auto_line
├ Improvements: ${improve_count} suggested
└ Files: retrospectives/, loop-reviews/, improvements/"

  log "Pipeline complete for: $SLUG"
}

# ─────────────────────────────────────────────────────────────
# MAIN EXECUTION
# ─────────────────────────────────────────────────────────────
main() {
  log "Starting post-review pipeline for: $SLUG"
  [ "$DRY_RUN" = true ] && log "[DRY-RUN MODE]"

  stage_retrospective
  stage_automation
  stage_consumer_routing
  stage_loop_review
  stage_improvement
  send_loop_summary

  log "All 5 stages complete for: $SLUG"
}

main
