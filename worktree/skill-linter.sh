#!/bin/bash
# Skill Linter — Deterministic SKILL.md quality checker
# Validates against the 47 Skill Authoring Rules (automatable subset).
#
# Usage: skill-linter.sh <skill-md-file> [--json]
# Exit code: 0 = pass, 1 = errors found, 2 = usage error
#
# Output (default): human-readable report
# Output (--json):  {"pass": bool, "errors": [...], "warnings": [...], "score": N}
#
# This script checks ONLY deterministic rules. Non-deterministic rules
# (conciseness, freedom-fragility matching, example quality) are deferred
# to the AI review tier in quality-gate.sh.

set -euo pipefail

# ─── Args ────────────────────────────────────────────────────────────────────

SKILL_FILE=""
JSON_OUTPUT=false

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_OUTPUT=true; shift ;;
    --help|-h)
      echo "Usage: skill-linter.sh <SKILL.md> [--json]"
      echo ""
      echo "Deterministic linter for SKILL.md files."
      echo "Checks naming, structure, line count, description format, etc."
      exit 0
      ;;
    -*) echo "Unknown flag: $1" >&2; exit 2 ;;
    *) SKILL_FILE="$1"; shift ;;
  esac
done

if [ -z "$SKILL_FILE" ]; then
  echo "Error: SKILL.md file path required" >&2
  echo "Usage: skill-linter.sh <SKILL.md> [--json]" >&2
  exit 2
fi

if [ ! -f "$SKILL_FILE" ]; then
  echo "Error: file not found: $SKILL_FILE" >&2
  exit 2
fi

# ─── State ───────────────────────────────────────────────────────────────────

ERRORS=()
WARNINGS=()
SKILL_DIR="$(cd "$(dirname "$SKILL_FILE")" && pwd)"

# ─── Helper: extract YAML frontmatter ────────────────────────────────────────

extract_frontmatter_field() {
  local field="$1"
  # Match field in YAML frontmatter (between first two --- lines)
  sed -n '/^---$/,/^---$/p' "$SKILL_FILE" | grep -E "^${field}:" | sed "s/^${field}:[[:space:]]*//" | sed 's/^["'"'"']//;s/["'"'"']$//'
}

# ─── Rule Checks ─────────────────────────────────────────────────────────────

# R3/R47: SKILL.md body ≤ 500 lines (hard limit)
check_line_count() {
  local lines
  lines=$(wc -l < "$SKILL_FILE" | tr -d ' ')
  if [ "$lines" -gt 500 ]; then
    ERRORS+=("R3: SKILL.md is ${lines} lines (max 500). Move excess to reference/ files.")
  elif [ "$lines" -gt 400 ]; then
    WARNINGS+=("R3: SKILL.md is ${lines} lines (approaching 500 limit). Consider splitting.")
  fi
}

# R5: Description exists and is specific
check_description_exists() {
  local desc
  desc="$(extract_frontmatter_field 'description')"
  if [ -z "$desc" ]; then
    ERRORS+=("R5: No 'description' field in YAML frontmatter.")
    return
  fi

  # R5/R7: Description ≤ 1024 chars
  local desc_len=${#desc}
  if [ "$desc_len" -gt 1024 ]; then
    ERRORS+=("R7: Description is ${desc_len} chars (max 1024).")
  fi

  # R4: Description in third person (no "I" or "You" at start)
  if echo "$desc" | grep -qE '^(I |You |My |Your )'; then
    ERRORS+=("R4: Description starts with first/second person. Use third person: 'Validates...' not 'I validate...'")
  fi

  # R5: Description should contain trigger keywords
  if ! echo "$desc" | grep -qiE '(use when|trigger|invoke|activate|run when)'; then
    WARNINGS+=("R5: Description should specify when to trigger (e.g., 'Use when...').")
  fi
}

# R7: Name format — lowercase-hyphens, ≤64 chars
check_name_format() {
  local name
  name="$(extract_frontmatter_field 'name')"
  if [ -z "$name" ]; then
    ERRORS+=("R7: No 'name' field in YAML frontmatter.")
    return
  fi

  local name_len=${#name}
  if [ "$name_len" -gt 64 ]; then
    ERRORS+=("R7: Name '${name}' is ${name_len} chars (max 64).")
  fi

  if ! echo "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
    ERRORS+=("R7: Name '${name}' must be lowercase-hyphens only (e.g., 'processing-pdfs').")
  fi

  # R6: Gerund form (name should contain a gerund-like word)
  if ! echo "$name" | grep -qE '(ing|tion|ment|ysis)'; then
    WARNINGS+=("R6: Name '${name}' should use gerund form (e.g., 'processing-pdfs' not 'pdf-processor').")
  fi
}

# R15: No nested references (reference files must not link to other reference files)
check_no_nested_refs() {
  local ref_dir="$SKILL_DIR/reference"
  if [ ! -d "$ref_dir" ]; then
    return
  fi

  # Check if any reference file contains links to other reference/ files
  local nested
  nested=$(grep -rlE '\]\(.*reference/' "$ref_dir" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$nested" -gt 0 ]; then
    ERRORS+=("R15: Found ${nested} reference file(s) linking to other reference/ files. References must be flat (SKILL.md → ref, never ref → ref).")
  fi
}

# R16: Long references need TOC (>100 lines without ## headings in first 20 lines)
check_ref_toc() {
  local ref_dir="$SKILL_DIR/reference"
  if [ ! -d "$ref_dir" ]; then
    return
  fi

  for ref_file in "$ref_dir"/*.md; do
    [ -f "$ref_file" ] || continue
    local ref_lines
    ref_lines=$(wc -l < "$ref_file" | tr -d ' ')
    if [ "$ref_lines" -gt 100 ]; then
      # Check if first 20 lines contain a table of contents pattern
      local has_toc
      has_toc=$(head -20 "$ref_file" | grep -ciE '(table of contents|toc|## contents|^- \[)' || true)
      if [ "$has_toc" -eq 0 ]; then
        local basename
        basename=$(basename "$ref_file")
        WARNINGS+=("R16: reference/${basename} is ${ref_lines} lines but has no TOC in first 20 lines.")
      fi
    fi
  done
}

# R33: Unix paths only (no backslashes in paths)
check_unix_paths() {
  local backslashes
  backslashes=$(grep -cE '\\[a-zA-Z]' "$SKILL_FILE" 2>/dev/null || true)
  if [ "$backslashes" -gt 0 ]; then
    ERRORS+=("R33: Found ${backslashes} potential Windows-style paths (backslashes). Use Unix paths only.")
  fi
}

# R44: Descriptive filenames (no doc1.md, file2.txt patterns)
check_descriptive_filenames() {
  local ref_dir="$SKILL_DIR/reference"
  if [ ! -d "$ref_dir" ]; then
    return
  fi

  for ref_file in "$ref_dir"/*; do
    [ -f "$ref_file" ] || continue
    local basename
    basename=$(basename "$ref_file")
    if echo "$basename" | grep -qE '^(doc|file|ref|data|temp)[0-9]'; then
      ERRORS+=("R44: Non-descriptive filename 'reference/${basename}'. Use descriptive names like 'form_validation_rules.md'.")
    fi
  done
}

# R14: Scripts ratio — many inline bash blocks suggest need for scripts/ dir
check_inline_scripts() {
  local bash_blocks
  bash_blocks=$(grep -c '```bash' "$SKILL_FILE" 2>/dev/null || true)
  local sh_blocks
  sh_blocks=$(grep -c '```sh' "$SKILL_FILE" 2>/dev/null || true)
  local total=$((bash_blocks + sh_blocks))

  if [ "$total" -gt 5 ]; then
    WARNINGS+=("R14: ${total} inline bash/sh blocks found. Consider moving scripts to scripts/ directory for execution.")
  fi
}

# R34: Defaults not choices — flag choice-giving patterns
check_defaults_not_choices() {
  local choices
  choices=$(grep -ciE '(you can (use|choose)|either .* or|choose between|option [A-C]|alternatively)' "$SKILL_FILE" 2>/dev/null || true)
  if [ "$choices" -gt 2 ]; then
    WARNINGS+=("R34: ${choices} choice-giving patterns found. Prefer giving defaults: 'use pdfplumber' > 'use A or B or C'.")
  fi
}

# R19: Feedback loop required — must have validation/iteration pattern
check_feedback_loop() {
  local has_loop
  has_loop=$(grep -ciE '(validate.*fix|verify.*correct|check.*adjust|feedback.*loop|iterate|re-run|retry|until pass)' "$SKILL_FILE" 2>/dev/null || true)
  if [ "$has_loop" -eq 0 ]; then
    WARNINGS+=("R19: No feedback/validation loop detected. Skills should include 'validate → fix → repeat' pattern.")
  fi
}

# R42: Dependencies declared
check_dependencies() {
  local has_deps
  has_deps=$(grep -ciE '(requires|dependencies|prerequisites|pip install|npm install|brew install|apt install)' "$SKILL_FILE" 2>/dev/null || true)
  # Also check scripts/ directory
  local scripts_dir="$SKILL_DIR/scripts"
  if [ -d "$scripts_dir" ]; then
    local script_deps
    script_deps=$(grep -rciE '(pip install|npm install|import |require\()' "$scripts_dir" 2>/dev/null || true)
    if [ "$script_deps" -gt 0 ] && [ "$has_deps" -eq 0 ]; then
      WARNINGS+=("R42: Scripts use imports but SKILL.md doesn't declare dependencies.")
    fi
  fi
}

# R45: MCP tools use fully qualified names
check_mcp_tool_names() {
  local mcp_refs
  mcp_refs=$(grep -cE 'mcp__[a-z]+__[a-z]' "$SKILL_FILE" 2>/dev/null || true)
  local bare_tool_refs
  bare_tool_refs=$(grep -cE '(call|use|invoke) [a-z_]+ tool' "$SKILL_FILE" 2>/dev/null || true)

  if [ "$bare_tool_refs" -gt 0 ] && [ "$mcp_refs" -eq 0 ]; then
    WARNINGS+=("R45: References to tools found but no fully-qualified MCP names (e.g., 'mcp__server__tool_name').")
  fi
}

# R36: No magic numbers without explanation
check_magic_numbers() {
  # Look for standalone numbers in config-like contexts
  local magic
  magic=$(grep -cE '(timeout|interval|limit|max|min|threshold|retry|count)[[:space:]]*[:=][[:space:]]*[0-9]+[^a-z]' "$SKILL_FILE" 2>/dev/null || true)
  local commented
  commented=$(grep -cE '(timeout|interval|limit|max|min|threshold|retry|count)[[:space:]]*[:=][[:space:]]*[0-9]+.*#|//' "$SKILL_FILE" 2>/dev/null || true)

  if [ "$magic" -gt 0 ] && [ "$commented" -eq 0 ]; then
    WARNINGS+=("R36: ${magic} numeric constants found without comments explaining why. Add # comments.")
  fi
}

# BONUS: Check for empty/boilerplate content
check_no_boilerplate() {
  local placeholders
  placeholders=$(grep -ciE '(TODO|FIXME|PLACEHOLDER|TBD|FILL IN|REPLACE THIS|YOUR .* HERE)' "$SKILL_FILE" 2>/dev/null || true)
  if [ "$placeholders" -gt 0 ]; then
    ERRORS+=("BOILERPLATE: ${placeholders} placeholder(s) found (TODO/TBD/FILL IN). Skill must be complete.")
  fi
}

# ─── Run All Checks ──────────────────────────────────────────────────────────

check_line_count
check_description_exists
check_name_format
check_no_nested_refs
check_ref_toc
check_unix_paths
check_descriptive_filenames
check_inline_scripts
check_defaults_not_choices
check_feedback_loop
check_dependencies
check_mcp_tool_names
check_magic_numbers
check_no_boilerplate

# ─── Output ──────────────────────────────────────────────────────────────────

num_errors=${#ERRORS[@]}
num_warnings=${#WARNINGS[@]}
passed=$( [ "$num_errors" -eq 0 ] && echo true || echo false )

# Score: 10 - (errors * 2) - (warnings * 0.5), clamped to 0-10
score=$(echo "10 - ($num_errors * 2) - ($num_warnings * 0.5)" | bc 2>/dev/null || echo "0")
# Clamp
if echo "$score" | grep -q '^-'; then score="0"; fi
score_int=$(echo "$score" | cut -d. -f1)
if [ -z "$score_int" ] || [ "$score_int" -gt 10 ]; then score_int=10; fi

if [ "$JSON_OUTPUT" = true ]; then
  # Build JSON arrays
  errors_json="[]"
  if [ "$num_errors" -gt 0 ]; then
    errors_json="$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .)"
  fi
  warnings_json="[]"
  if [ "$num_warnings" -gt 0 ]; then
    warnings_json="$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)"
  fi

  jq -n \
    --argjson pass "$passed" \
    --argjson errors "$errors_json" \
    --argjson warnings "$warnings_json" \
    --argjson num_errors "$num_errors" \
    --argjson num_warnings "$num_warnings" \
    --argjson score "$score_int" \
    --arg file "$SKILL_FILE" \
    '{
      pass: $pass,
      file: $file,
      errors: $errors,
      warnings: $warnings,
      num_errors: $num_errors,
      num_warnings: $num_warnings,
      score: $score
    }'
else
  # Human-readable output
  echo "=== Skill Linter Report ==="
  echo "File: $SKILL_FILE"
  echo "Score: ${score_int}/10"
  echo ""

  if [ "$num_errors" -gt 0 ]; then
    echo "ERRORS (${num_errors}) — must fix:"
    for e in "${ERRORS[@]}"; do
      echo "  ❌ $e"
    done
    echo ""
  fi

  if [ "$num_warnings" -gt 0 ]; then
    echo "WARNINGS (${num_warnings}) — should fix:"
    for w in "${WARNINGS[@]}"; do
      echo "  ⚠️  $w"
    done
    echo ""
  fi

  if [ "$num_errors" -eq 0 ] && [ "$num_warnings" -eq 0 ]; then
    echo "✅ All checks passed!"
  elif [ "$num_errors" -eq 0 ]; then
    echo "✅ PASS (with ${num_warnings} warning(s))"
  else
    echo "❌ FAIL (${num_errors} error(s), ${num_warnings} warning(s))"
  fi
fi

# Exit code: 0 = pass, 1 = errors found
[ "$num_errors" -eq 0 ] && exit 0 || exit 1
