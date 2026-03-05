#!/bin/bash
# Parse Claude stream-json output to extract session_id, cost, and token usage.
# Ported from Paperclip's parseClaudeStreamJson (TypeScript) to bash+jq.
#
# Usage:
#   parse-session.sh <session-file.json>
#   parse-session.sh <session-file.json> --save-cost <output-dir> --task-id <id> --worker-id <id>
#   parse-session.sh <session-file.json> --save-session <output-dir> --task-id <id>
#
# Output (stdout): JSON with session_id, model, cost_usd, input_tokens, output_tokens, cached_tokens
#
# Adapted from: https://github.com/paperclipai/paperclip
# packages/adapters/claude-local/src/server/parse.ts

set -euo pipefail

SESSION_FILE="${1:-}"
shift || true

if [ -z "$SESSION_FILE" ] || [ ! -f "$SESSION_FILE" ]; then
  echo "Error: session file required and must exist" >&2
  echo "Usage: parse-session.sh <session-file.json> [--save-cost <dir> --task-id <id> --worker-id <id>]" >&2
  exit 1
fi

# Parse optional flags
SAVE_COST_DIR=""
SAVE_SESSION_DIR=""
TASK_ID=""
WORKER_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --save-cost) SAVE_COST_DIR="$2"; shift 2 ;;
    --save-session) SAVE_SESSION_DIR="$2"; shift 2 ;;
    --task-id) TASK_ID="$2"; shift 2 ;;
    --worker-id) WORKER_ID="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Extract session_id from the init event (first system/init line)
SESSION_ID="$(grep -m1 '"subtype"' "$SESSION_FILE" 2>/dev/null \
  | grep '"init"' \
  | jq -r '.session_id // empty' 2>/dev/null || true)"

# Extract model from init event
MODEL="$(grep -m1 '"subtype"' "$SESSION_FILE" 2>/dev/null \
  | grep '"init"' \
  | jq -r '.model // empty' 2>/dev/null || true)"

# Extract the result event (last line with "type":"result")
# This contains cost, usage, session_id, and summary
RESULT_LINE="$(grep '"type":"result"' "$SESSION_FILE" 2>/dev/null | tail -1 || true)"

if [ -z "$RESULT_LINE" ]; then
  # Fallback: try with spaces in JSON (pretty-printed)
  RESULT_LINE="$(grep '"type": "result"' "$SESSION_FILE" 2>/dev/null | tail -1 || true)"
fi

COST_USD="0"
INPUT_TOKENS="0"
OUTPUT_TOKENS="0"
CACHED_TOKENS="0"
RESULT_SESSION_ID=""

if [ -n "$RESULT_LINE" ]; then
  COST_USD="$(echo "$RESULT_LINE" | jq -r '.total_cost_usd // 0' 2>/dev/null || echo 0)"
  INPUT_TOKENS="$(echo "$RESULT_LINE" | jq -r '.usage.input_tokens // 0' 2>/dev/null || echo 0)"
  OUTPUT_TOKENS="$(echo "$RESULT_LINE" | jq -r '.usage.output_tokens // 0' 2>/dev/null || echo 0)"
  CACHED_TOKENS="$(echo "$RESULT_LINE" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null || echo 0)"
  RESULT_SESSION_ID="$(echo "$RESULT_LINE" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi

# Prefer session_id from result event (most recent), fall back to init event
FINAL_SESSION_ID="${RESULT_SESSION_ID:-$SESSION_ID}"

# Build output JSON
OUTPUT="$(jq -n \
  --arg session_id "$FINAL_SESSION_ID" \
  --arg model "$MODEL" \
  --argjson cost_usd "$COST_USD" \
  --argjson input_tokens "$INPUT_TOKENS" \
  --argjson output_tokens "$OUTPUT_TOKENS" \
  --argjson cached_tokens "$CACHED_TOKENS" \
  --arg task_id "$TASK_ID" \
  --arg worker_id "$WORKER_ID" \
  --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    session_id: $session_id,
    model: $model,
    cost_usd: $cost_usd,
    usage: {
      input_tokens: $input_tokens,
      output_tokens: $output_tokens,
      cached_tokens: $cached_tokens
    },
    task_id: (if $task_id == "" then null else $task_id end),
    worker_id: (if $worker_id == "" then null else $worker_id end),
    timestamp: $timestamp
  }'
)"

echo "$OUTPUT"

# Save cost data if requested
if [ -n "$SAVE_COST_DIR" ] && [ -n "$WORKER_ID" ]; then
  mkdir -p "$SAVE_COST_DIR"
  local_id="${TASK_ID:-unknown}"
  echo "$OUTPUT" > "$SAVE_COST_DIR/${WORKER_ID}-${local_id}.json"
fi

# Save session ID for resume if requested
if [ -n "$SAVE_SESSION_DIR" ] && [ -n "$FINAL_SESSION_ID" ] && [ -n "$TASK_ID" ]; then
  mkdir -p "$SAVE_SESSION_DIR"
  echo "$FINAL_SESSION_ID" > "$SAVE_SESSION_DIR/${TASK_ID}.session"
fi
