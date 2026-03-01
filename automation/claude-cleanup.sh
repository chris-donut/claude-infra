#!/bin/bash
# Claude Code Orphaned Process Cleanup
# Kills leaked subagent processes that accumulate from claude-mem plugin hooks.
#
# Root cause: claude-mem's worker-service.cjs spawns `claude --disallowedTools ...`
# processes for summarization. When parent sessions close, these grandchild processes
# aren't reaped because SIGHUP doesn't propagate through the process tree.
#
# Safe to run anytime — only kills idle subagent workers, never touches:
#   - Active Cursor Claude Code sessions (native-binary/claude)
#   - Claude Desktop app
#   - claude-mem daemon (worker-service.cjs)
#   - telegram-monitor
#
# Usage:
#   bash scripts/automation/claude-cleanup.sh          # normal cleanup
#   bash scripts/automation/claude-cleanup.sh --quiet   # for cron/launchd (no output)
#   bash scripts/automation/claude-cleanup.sh --dry-run  # show what would be killed

QUIET=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=true ;;
    --dry-run) DRY_RUN=true ;;
  esac
done

log() { $QUIET || echo "$1"; }

# ─── 1. Kill orphaned CLI subagents ─────────────────────────────
# These have --disallowedTools (pure LLM inference, no tool access)
SUBAGENT_PIDS=$(ps aux | grep '[/].local/bin/claude' | grep -- '--disallowedTools' | awk '{print $2}') || true
SUBAGENT_COUNT=0
if [ -n "$SUBAGENT_PIDS" ]; then
  SUBAGENT_COUNT=$(echo "$SUBAGENT_PIDS" | wc -l | tr -d ' ')
fi

if [ "$SUBAGENT_COUNT" -gt 0 ]; then
  SUBAGENT_MEM=$(ps aux | grep '[/].local/bin/claude' | grep -- '--disallowedTools' | awk '{sum += $6} END {printf "%.0f", sum/1024}') || true
  if $DRY_RUN; then
    log "[DRY-RUN] Would kill $SUBAGENT_COUNT orphaned subagents (~${SUBAGENT_MEM:-0} MB)"
  else
    echo "$SUBAGENT_PIDS" | xargs kill 2>/dev/null || true
    log "[CLEANED] $SUBAGENT_COUNT orphaned subagents (~${SUBAGENT_MEM:-0} MB freed)"
  fi
else
  log "[OK] No orphaned subagents found"
fi

# ─── 2. Kill orphaned claude-mem MCP servers ────────────────────
# Each Cursor session spawns its own mcp-server.cjs. Dead sessions leave them behind.
MCP_PIDS=$(ps aux | grep '[n]ode.*claude-mem.*mcp-server' | awk '{print $2}') || true
MCP_COUNT=0
if [ -n "$MCP_PIDS" ]; then
  MCP_COUNT=$(echo "$MCP_PIDS" | wc -l | tr -d ' ')
fi

# Only clean if there are more MCP servers than active Cursor sessions
CURSOR_COUNT=$(ps aux | grep '[n]ative-binary/claude' | wc -l | tr -d ' ') || true
CURSOR_COUNT=${CURSOR_COUNT:-0}

if [ "$MCP_COUNT" -gt "$CURSOR_COUNT" ]; then
  EXCESS=$((MCP_COUNT - CURSOR_COUNT))
  if $DRY_RUN; then
    log "[DRY-RUN] Would kill ~$EXCESS excess MCP servers (have $MCP_COUNT, need $CURSOR_COUNT)"
  else
    echo "$MCP_PIDS" | sort -n | head -n "$EXCESS" | xargs kill 2>/dev/null || true
    log "[CLEANED] $EXCESS excess claude-mem MCP servers"
  fi
else
  log "[OK] MCP server count ($MCP_COUNT) matches active sessions ($CURSOR_COUNT)"
fi

# ─── 3. Summary ─────────────────────────────────────────────────
TOTAL_NOW=$(ps aux | grep -E '[Cc]laude|[c]laude-mem' | awk '{sum += $6} END {printf "%.0f", sum/1024}') || true
log "[TOTAL] Claude processes now using ~${TOTAL_NOW:-0} MB"
