#!/bin/bash
# Generate environment context snapshot
# Outputs to .claude/context/environment.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPO_ROOT/.claude/context/environment.md"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" << HEADER
# Environment Context
Generated: $TIMESTAMP

## System
- OS: $(sw_vers -productName 2>/dev/null || echo "Unknown") $(sw_vers -productVersion 2>/dev/null || echo "")
- Kernel: $(uname -sr)
- Shell: $SHELL
- Working directory: $REPO_ROOT

## Runtime Versions
HEADER

# Runtime versions (check each, show "not installed" if missing)
for cmd_pair in "node:node -v" "bun:bun -v" "pnpm:pnpm -v" "npm:npm -v" "python3:python3 --version" "docker:docker --version"; do
  name="${cmd_pair%%:*}"
  cmd="${cmd_pair#*:}"
  if command -v "$name" &>/dev/null; then
    version="$($cmd 2>/dev/null | head -1 | sed 's/.*version //' | sed 's/,.*//')"
    echo "- $name: $version" >> "$OUTPUT"
  else
    echo "- $name: not installed" >> "$OUTPUT"
  fi
done

# Running services on common dev ports
cat >> "$OUTPUT" << 'SERVICES'

## Running Services
SERVICES

if command -v lsof &>/dev/null; then
  lsof -i -P -n 2>/dev/null | grep LISTEN | awk '{print $1, $9}' | sort -u | while read -r proc addr; do
    port="${addr##*:}"
    case "$port" in
      3000|3001|3100|4000|5000|5173|8000|8080|8888|18789)
        echo "- Port $port: $proc" >> "$OUTPUT"
        ;;
    esac
  done
fi

# Check if any ports were found
if ! grep -q "^- Port" "$OUTPUT" 2>/dev/null; then
  echo "- No dev services detected on common ports" >> "$OUTPUT"
fi

# Environment variables (presence only, never values)
cat >> "$OUTPUT" << 'ENVVARS'

## Environment Variables (set/not set)
ENVVARS

for var in LINEAR_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY CLAUDE_CODE_TEAM_NAME CLAUDE_CODE_AGENT_ID USE_OPENCLAW INFISICAL_TOKEN GOOGLE_CLIENT_ID; do
  if [ -n "${!var:-}" ]; then
    echo "- $var: set" >> "$OUTPUT"
  else
    echo "- $var: not set" >> "$OUTPUT"
  fi
done

# Available CLI tools
cat >> "$OUTPUT" << 'TOOLS'

## Available CLI Tools
TOOLS

for tool in git gh tmux gcloud docker kubectl caddy infisical mise; do
  if command -v "$tool" &>/dev/null; then
    echo "- $tool: available" >> "$OUTPUT"
  else
    echo "- $tool: not available" >> "$OUTPUT"
  fi
done

echo "Generated environment context: $OUTPUT"
