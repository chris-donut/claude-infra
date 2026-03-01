#!/bin/bash
# Generate architecture context snapshot
# Outputs to .claude/context/architecture.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$REPO_ROOT/.claude/context/architecture.md"
TIMESTAMP="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" << EOF
# Architecture Context
Generated: $TIMESTAMP

## Project: donut-product-dev
Location: $REPO_ROOT

## Sub-Applications
EOF

# Scan for package.json files (skip node_modules, .next, openclaw internals)
find "$REPO_ROOT" -name "package.json" -maxdepth 3 \
  -not -path "*/node_modules/*" \
  -not -path "*/.next/*" \
  -not -path "*/openclaw/integrations/*" \
  -not -path "*/openclaw/extensions/*" \
  2>/dev/null | sort | while read -r pkg; do
  dir="$(dirname "$pkg")"
  rel_dir="${dir#"$REPO_ROOT"/}"

  # Skip root package.json if it exists
  [ "$dir" = "$REPO_ROOT" ] && continue

  name="$(python3 -c "import json; print(json.load(open('$pkg')).get('name', 'unnamed'))" 2>/dev/null || echo "unnamed")"

  # Detect framework
  framework="unknown"
  if grep -q '"next"' "$pkg" 2>/dev/null; then
    next_ver="$(python3 -c "import json; d=json.load(open('$pkg')).get('dependencies',{}); print(d.get('next','unknown'))" 2>/dev/null)"
    framework="Next.js $next_ver"
  elif grep -q '"react"' "$pkg" 2>/dev/null; then
    framework="React"
  elif grep -q '"express"' "$pkg" 2>/dev/null; then
    framework="Express"
  elif grep -q '"hono"' "$pkg" 2>/dev/null; then
    framework="Hono"
  fi

  echo "| $rel_dir | $name | $framework |" >> "$OUTPUT"
done

# Add table header before the rows (insert at line after "## Sub-Applications")
# We need to prepend the header - use sed
sed -i '' '/^## Sub-Applications$/a\
\
| Directory | Package Name | Framework |\
|-----------|-------------|-----------|' "$OUTPUT"

# Skills available
echo "" >> "$OUTPUT"
echo "## Skills Available" >> "$OUTPUT"

SKILLS_DIR="$REPO_ROOT/donut-product/skills"
if [ -d "$SKILLS_DIR" ]; then
  for skill_dir in "$SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    skill_name="$(basename "$skill_dir")"
    skill_file="$skill_dir/SKILL.md"
    if [ -f "$skill_file" ]; then
      # Extract description from SKILL.md frontmatter
      desc="$(sed -n '/^description:/s/^description: //p' "$skill_file" | head -1 | cut -c1-80)"
      echo "- **$skill_name**: $desc" >> "$OUTPUT"
    else
      echo "- **$skill_name**: (no SKILL.md)" >> "$OUTPUT"
    fi
  done
else
  echo "- Skills directory not found" >> "$OUTPUT"
fi

# OpenClaw agents (read-only scan)
echo "" >> "$OUTPUT"
echo "## OpenClaw Agents" >> "$OUTPUT"

OPENCLAW_DIR="$REPO_ROOT/openclaw"
if [ -d "$OPENCLAW_DIR/workspace" ]; then
  for agent_dir in "$OPENCLAW_DIR/workspace"/*/; do
    [ -d "$agent_dir" ] || continue
    agent_name="$(basename "$agent_dir")"
    [ "$agent_name" = "tools" ] && continue
    soul_file="$agent_dir/SOUL.md"
    if [ -f "$soul_file" ]; then
      echo "- **$agent_name**: has SOUL.md" >> "$OUTPUT"
    else
      echo "- **$agent_name**: no SOUL.md" >> "$OUTPUT"
    fi
  done

  # Check AGENTS.md
  if [ -f "$OPENCLAW_DIR/workspace/AGENTS.md" ]; then
    echo "- Operating manual: openclaw/workspace/AGENTS.md" >> "$OUTPUT"
  fi
else
  echo "- OpenClaw workspace not found" >> "$OUTPUT"
fi

# Key directories
echo "" >> "$OUTPUT"
echo "## Directory Structure" >> "$OUTPUT"
echo '```' >> "$OUTPUT"
ls -1d "$REPO_ROOT"/*/ 2>/dev/null | while read -r d; do
  echo "$(basename "$d")/"
done >> "$OUTPUT"
echo '```' >> "$OUTPUT"

echo "Generated architecture context: $OUTPUT"
