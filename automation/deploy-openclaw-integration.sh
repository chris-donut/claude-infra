#!/bin/bash
# Deploy OpenClaw <-> Claude Code integration on GCP VM
# Run this script ON the GCP VM (openclaw-gateway)
#
# TODO [2026-03-01]: Paths in this script still reference old structure:
#   - REPO_DIR uses "donut-product-dev" (should match GCP VM actual clone path)
#   - Container mount paths use "/workspace/donut-product-dev"
#   - task-queue.sh fallback paths use "/home/chrizhuu/donut-product-dev"
#   - SOUL.md references use "/workspace/donut-product-dev"
#   Keep GCP VM paths as-is for now; update when re-deploying.
#
# What it does:
#   Phase 1: Clones donut-product repo, mounts into container, updates SOUL.md
#   Phase 2: Adds GitHub MCP server to openclaw.json
#   Phase 3: Adds bidirectional task dispatch (OpenClaw -> task-queue)
#   Sets up cron for auto-sync
#
# Usage:
#   bash deploy-openclaw-integration.sh [--github-token TOKEN]

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────

OPENCLAW_DIR="$HOME/openclaw"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
SOUL_MD="$HOME/.openclaw/workspace/SOUL.md"
DOCKER_COMPOSE="$OPENCLAW_DIR/docker-compose.yml"
REPO_DIR="$HOME/donut-product-dev"
REPO_URL="https://github.com/DonutLabs-ai/donut-product.git"
BACKUP_DIR="$HOME/.openclaw/backups/$(date +%Y%m%d-%H%M%S)"

GITHUB_TOKEN="${1:-}"
if [ "$GITHUB_TOKEN" = "--github-token" ]; then
  GITHUB_TOKEN="${2:-}"
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*"; }
backup() {
  local file="$1"
  if [ -f "$file" ]; then
    mkdir -p "$BACKUP_DIR"
    cp "$file" "$BACKUP_DIR/$(basename "$file")"
    log "Backed up: $file -> $BACKUP_DIR/"
  fi
}

# ─── Pre-flight Checks ────────────────────────────────────────────────────────

log "=== Pre-flight checks ==="

if ! command -v docker &>/dev/null; then
  echo "ERROR: docker not found" >&2; exit 1
fi
if ! command -v git &>/dev/null; then
  echo "ERROR: git not found" >&2; exit 1
fi
if ! command -v jq &>/dev/null; then
  log "Installing jq..."
  sudo apt-get install -y jq 2>/dev/null || sudo yum install -y jq 2>/dev/null
fi

log "Pre-flight OK"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Shared Context — Clone repo, mount into container, update SOUL.md
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "=== PHASE 1: Shared Context ==="

# 1a. Clone or update the repo
if [ -d "$REPO_DIR/.git" ]; then
  log "Repo exists, pulling latest..."
  cd "$REPO_DIR"
  git pull origin main 2>/dev/null || log "WARN: git pull failed (may need auth)"
  cd -
else
  log "Cloning donut-product-dev..."
  git clone "$REPO_URL" "$REPO_DIR" 2>/dev/null || {
    log "WARN: Clone with HTTPS failed, trying with gh..."
    if command -v gh &>/dev/null; then
      gh repo clone DonutLabs-ai/donut-product "$REPO_DIR"
    else
      log "ERROR: Cannot clone repo. Please clone manually:"
      log "  git clone $REPO_URL $REPO_DIR"
      log "Continuing with remaining steps..."
    fi
  }
fi

# 1b. Patch docker-compose.yml to add volume mount
backup "$DOCKER_COMPOSE"

if [ -f "$DOCKER_COMPOSE" ]; then
  # Check if the volume mount already exists
  if grep -q "donut-product-dev" "$DOCKER_COMPOSE"; then
    log "Volume mount for donut-product-dev already in docker-compose.yml"
  else
    log "Adding volume mount to docker-compose.yml..."
    # Use python3 for safe YAML manipulation (available on most GCP VMs)
    python3 << 'PYEOF'
import sys

compose_path = sys.argv[1] if len(sys.argv) > 1 else "/home/chrizhuu/openclaw/docker-compose.yml"
repo_dir = sys.argv[2] if len(sys.argv) > 2 else "/home/chrizhuu/donut-product-dev"

with open(compose_path) as f:
    content = f.read()

# Find the volumes section of the main service and add our mount
# Strategy: find "volumes:" under the main service, add after last "- " line in that block
lines = content.split('\n')
new_lines = []
in_volumes = False
volumes_indent = 0
last_volume_idx = -1

for i, line in enumerate(lines):
    stripped = line.lstrip()
    current_indent = len(line) - len(stripped)

    if stripped.startswith('volumes:') and current_indent > 0:
        in_volumes = True
        volumes_indent = current_indent
    elif in_volumes:
        if stripped.startswith('- ') and current_indent > volumes_indent:
            last_volume_idx = len(new_lines)
        elif stripped and current_indent <= volumes_indent:
            in_volumes = False

    new_lines.append(line)

if last_volume_idx >= 0:
    # Detect the indent of volume entries
    vol_line = new_lines[last_volume_idx]
    vol_indent = len(vol_line) - len(vol_line.lstrip())
    indent = ' ' * vol_indent
    # Insert two new volume mounts after the last existing one
    new_mounts = [
        f'{indent}- {repo_dir}:/workspace/donut-product-dev:ro',
        f'{indent}- {repo_dir}/scripts/worktree:/workspace/scripts/worktree:rw',
    ]
    for j, mount in enumerate(new_mounts):
        new_lines.insert(last_volume_idx + 1 + j, mount)

    with open(compose_path, 'w') as f:
        f.write('\n'.join(new_lines))
    print(f"Added volume mounts to {compose_path}")
else:
    print("WARN: Could not find volumes section in docker-compose.yml")
    print("Please add manually:")
    print(f"  - {repo_dir}:/workspace/donut-product-dev:ro")
    print(f"  - {repo_dir}/scripts/worktree:/workspace/scripts/worktree:rw")
PYEOF
  fi
else
  log "WARN: docker-compose.yml not found at $DOCKER_COMPOSE"
fi

# 1c. Update SOUL.md to reference CLAUDE.md and skills
backup "$SOUL_MD"

log "Updating SOUL.md with shared context references..."
cat > /tmp/soul-integration-patch.md << 'SOULEOF'

---

# Shared Context from Claude Code Ecosystem

You are connected to the Donut development ecosystem. The following resources are mounted from the donut-product-dev repository.

## Architecture & Instructions

Read `/workspace/donut-product-dev/CLAUDE.md` for comprehensive project instructions including:
- Full architecture overview (NestJS backend, FastAPI AI agent, React frontend, etc.)
- 33 development skills and their usage patterns
- Decision tree for task execution
- Code review standards

Read `/workspace/donut-product-dev/.claude/CLAUDE.md` for detailed agent context system including:
- Session lifecycle automation
- Context generation scripts
- State tracking (work-in-progress, completed tasks, blocked items)
- Automation map (hooks, crons, daemons)

## Key Context Files

These files provide real-time project state:
- `/workspace/donut-product-dev/.claude/context/architecture.md` — service map
- `/workspace/donut-product-dev/.claude/context/git-state.md` — branches, PRs, diffs
- `/workspace/donut-product-dev/.claude/context/work-in-progress.md` — active tasks

## Skills Reference

Skills are documented in `/workspace/donut-product-dev/skills/*/SKILL.md`. Key skills:
- `writing-plans` — structured task planning
- `systematic-debugging` — root cause analysis before fixing
- `verification-before-completion` — prove it works before claiming done
- `linear-issue-workflow` — Linear issue lifecycle

## Task Dispatch (Bidirectional)

When you receive a complex development task via Telegram/Slack that requires code changes:

1. **Simple questions** → Answer directly using your architecture knowledge
2. **Code changes needed** → Dispatch to the worker fleet:

```bash
bash /workspace/scripts/worktree/task-queue.sh add "task title" \
  --priority high \
  --description "Detailed description of what to implement"
```

After dispatching, tell the user:
"已将任务排入 Worker 队列。完成后会通过 Telegram 通知你。"

3. **Check task status**:
```bash
bash /workspace/scripts/worktree/task-queue.sh status
bash /workspace/scripts/worktree/task-queue.sh list --status pending
```

## Interaction Rules

- When asked about Donut architecture, read the CLAUDE.md files first
- When asked to create Linear issues, use the Linear MCP tools
- When asked to review code, read the PR review rules from `/workspace/donut-product-dev/.claude/rules/pr-review.md`
- For development tasks: dispatch to workers, don't attempt to code directly in this container
- Always respond in the same language as the user's message
SOULEOF

if [ -f "$SOUL_MD" ]; then
  # Check if integration section already exists
  if grep -q "Shared Context from Claude Code Ecosystem" "$SOUL_MD"; then
    log "SOUL.md already has integration section, replacing..."
    # Remove old integration section (from "# Shared Context" to end)
    python3 -c "
content = open('$SOUL_MD').read()
marker = '# Shared Context from Claude Code Ecosystem'
idx = content.find(marker)
if idx > 0:
    # Find the --- separator before our section
    sep_idx = content.rfind('---', 0, idx)
    if sep_idx > 0:
        content = content[:sep_idx].rstrip()
    else:
        content = content[:idx].rstrip()
    open('$SOUL_MD', 'w').write(content + '\n')
"
  fi
  cat /tmp/soul-integration-patch.md >> "$SOUL_MD"
  log "SOUL.md updated with shared context references"
else
  log "Creating new SOUL.md..."
  mkdir -p "$(dirname "$SOUL_MD")"
  echo "# OpenClaw Agent" > "$SOUL_MD"
  echo "" >> "$SOUL_MD"
  echo "You are an AI assistant integrated with the Donut development ecosystem." >> "$SOUL_MD"
  cat /tmp/soul-integration-patch.md >> "$SOUL_MD"
  log "Created new SOUL.md with integration"
fi

rm -f /tmp/soul-integration-patch.md

# 1d. Set up cron for auto-sync (every 30 minutes)
CRON_CMD="cd $REPO_DIR && git pull origin main --quiet 2>/dev/null"
if crontab -l 2>/dev/null | grep -q "donut-product-dev"; then
  log "Cron sync already exists"
else
  log "Adding cron job for repo sync (every 30 min)..."
  (crontab -l 2>/dev/null; echo "*/30 * * * * $CRON_CMD") | crontab -
  log "Cron job added"
fi

log "Phase 1 complete!"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 2: MCP Server Integration — Add GitHub MCP to openclaw.json
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "=== PHASE 2: MCP Server Integration ==="

backup "$OPENCLAW_CONFIG"

if [ -f "$OPENCLAW_CONFIG" ]; then
  log "Patching openclaw.json with MCP servers..."

  python3 << PYEOF
import json
import os

config_path = "$OPENCLAW_CONFIG"
github_token = "$GITHUB_TOKEN"

with open(config_path) as f:
    config = json.load(f)

# Ensure mcpServers section exists
if 'mcpServers' not in config:
    config['mcpServers'] = {}

servers = config['mcpServers']
changed = False

# Add GitHub MCP server
if 'github' not in servers and github_token:
    servers['github'] = {
        'command': 'npx',
        'args': ['-y', '@modelcontextprotocol/server-github'],
        'env': {
            'GITHUB_PERSONAL_ACCESS_TOKEN': github_token
        }
    }
    changed = True
    print("Added GitHub MCP server")
elif 'github' in servers:
    print("GitHub MCP server already configured")
elif not github_token:
    print("WARN: No GitHub token provided. Skip GitHub MCP.")
    print("  Re-run with: --github-token YOUR_TOKEN")

# Add filesystem MCP server (read-only access to the mounted repo)
if 'filesystem' not in servers:
    servers['filesystem'] = {
        'command': 'npx',
        'args': [
            '-y', '@modelcontextprotocol/server-filesystem',
            '/workspace/donut-product-dev'
        ]
    }
    changed = True
    print("Added Filesystem MCP server (read-only repo access)")
elif 'filesystem' in servers:
    print("Filesystem MCP server already configured")

if changed:
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    print(f"Updated {config_path}")
else:
    print("No MCP changes needed")
PYEOF

  # Ensure npx is available in the container
  log "Checking if npx is available in container..."
  CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i openclaw | head -1)
  if [ -n "$CONTAINER_NAME" ]; then
    docker exec "$CONTAINER_NAME" which npx 2>/dev/null && log "npx available in container" || {
      log "WARN: npx not found in container. MCP servers may not work."
      log "You may need to install Node.js in the container or use a different image."
    }
  fi
else
  log "WARN: openclaw.json not found at $OPENCLAW_CONFIG"
  log "Create it manually or check the OpenClaw docs."
fi

log "Phase 2 complete!"

# ══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Bidirectional Dispatch — Task Queue integration
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "=== PHASE 3: Bidirectional Task Dispatch ==="

# 3a. Ensure task-queue.sh is available and has jq
if [ -f "$REPO_DIR/scripts/worktree/task-queue.sh" ]; then
  chmod +x "$REPO_DIR/scripts/worktree/task-queue.sh"
  log "task-queue.sh is ready at $REPO_DIR/scripts/worktree/task-queue.sh"
else
  log "WARN: task-queue.sh not found. Will be available after repo clone/pull."
fi

# 3b. Ensure shared directory exists for task queue
SHARED_DIR="$REPO_DIR/.worktree-shared"
mkdir -p "$SHARED_DIR"
if [ ! -f "$SHARED_DIR/dev-tasks.json" ]; then
  echo '{"version":1,"tasks":[]}' > "$SHARED_DIR/dev-tasks.json"
  log "Initialized task queue at $SHARED_DIR/dev-tasks.json"
else
  log "Task queue already exists"
fi
touch "$SHARED_DIR/dev-task.lock"

# 3c. Create a convenience wrapper for OpenClaw to dispatch tasks
cat > "$HOME/.openclaw/workspace/dispatch-task.sh" << 'WRAPPER'
#!/bin/bash
# Convenience wrapper for dispatching tasks from OpenClaw
# Usage: dispatch-task.sh "task title" "description" [priority]
set -euo pipefail

TITLE="${1:?Usage: dispatch-task.sh \"title\" \"description\" [priority]}"
DESCRIPTION="${2:-$TITLE}"
PRIORITY="${3:-high}"
QUEUE_SCRIPT="/workspace/scripts/worktree/task-queue.sh"

if [ ! -f "$QUEUE_SCRIPT" ]; then
  # Fallback: try the host-mounted path
  QUEUE_SCRIPT="/home/chrizhuu/donut-product-dev/scripts/worktree/task-queue.sh"
fi

if [ -f "$QUEUE_SCRIPT" ]; then
  bash "$QUEUE_SCRIPT" add "$TITLE" --priority "$PRIORITY" --description "$DESCRIPTION"
else
  echo "ERROR: task-queue.sh not found"
  exit 1
fi
WRAPPER
chmod +x "$HOME/.openclaw/workspace/dispatch-task.sh"
log "Created dispatch-task.sh wrapper"

# 3d. Create a status check wrapper
cat > "$HOME/.openclaw/workspace/check-tasks.sh" << 'STATUS'
#!/bin/bash
# Check task queue status from OpenClaw
set -euo pipefail

QUEUE_SCRIPT="/workspace/scripts/worktree/task-queue.sh"
if [ ! -f "$QUEUE_SCRIPT" ]; then
  QUEUE_SCRIPT="/home/chrizhuu/donut-product-dev/scripts/worktree/task-queue.sh"
fi

if [ -f "$QUEUE_SCRIPT" ]; then
  echo "=== Task Queue Status ==="
  bash "$QUEUE_SCRIPT" status
  echo ""
  echo "=== Pending Tasks ==="
  bash "$QUEUE_SCRIPT" list --status pending
  echo ""
  echo "=== Recent Completions ==="
  bash "$QUEUE_SCRIPT" list --status completed 2>/dev/null | tail -5
else
  echo "ERROR: task-queue.sh not found"
  exit 1
fi
STATUS
chmod +x "$HOME/.openclaw/workspace/check-tasks.sh"
log "Created check-tasks.sh wrapper"

log "Phase 3 complete!"

# ══════════════════════════════════════════════════════════════════════════════
# RESTART
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "=== Restarting OpenClaw Container ==="

cd "$OPENCLAW_DIR"

if [ -f "$DOCKER_COMPOSE" ]; then
  log "Stopping container..."
  docker compose down 2>/dev/null || docker-compose down 2>/dev/null
  log "Starting container with new mounts..."
  docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null
  sleep 5
  log "Container status:"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -i openclaw || docker ps
else
  log "WARN: No docker-compose.yml found. Please restart manually."
fi

# ══════════════════════════════════════════════════════════════════════════════
# VERIFICATION
# ══════════════════════════════════════════════════════════════════════════════

log ""
log "=== Verification ==="

CONTAINER_NAME=$(docker ps --format '{{.Names}}' | grep -i openclaw | head -1)

if [ -n "$CONTAINER_NAME" ]; then
  log "Container: $CONTAINER_NAME is running"

  # Check mounts
  log "Checking volume mounts..."
  docker exec "$CONTAINER_NAME" ls /workspace/donut-product-dev/CLAUDE.md 2>/dev/null \
    && log "  ✓ CLAUDE.md mounted" \
    || log "  ✗ CLAUDE.md NOT mounted — check docker-compose volumes"

  docker exec "$CONTAINER_NAME" ls /workspace/scripts/worktree/task-queue.sh 2>/dev/null \
    && log "  ✓ task-queue.sh mounted" \
    || log "  ✗ task-queue.sh NOT mounted — check docker-compose volumes"

  docker exec "$CONTAINER_NAME" cat /workspace/donut-product-dev/CLAUDE.md 2>/dev/null | head -3 \
    && log "  ✓ CLAUDE.md readable" \
    || log "  ✗ CLAUDE.md NOT readable"

  # Check SOUL.md
  grep -q "Shared Context from Claude Code Ecosystem" "$SOUL_MD" 2>/dev/null \
    && log "  ✓ SOUL.md has integration section" \
    || log "  ✗ SOUL.md missing integration section"

  # Check MCP config
  python3 -c "
import json
with open('$OPENCLAW_CONFIG') as f:
    c = json.load(f)
servers = c.get('mcpServers', {})
if 'github' in servers: print('  ✓ GitHub MCP configured')
else: print('  ✗ GitHub MCP not configured')
if 'filesystem' in servers: print('  ✓ Filesystem MCP configured')
else: print('  ✗ Filesystem MCP not configured')
" 2>/dev/null

  # Check cron
  crontab -l 2>/dev/null | grep -q "donut-product-dev" \
    && log "  ✓ Cron sync active" \
    || log "  ✗ Cron sync not set"

else
  log "WARN: No OpenClaw container running"
fi

log ""
log "══════════════════════════════════════════════════"
log " Deployment Complete!"
log "══════════════════════════════════════════════════"
log ""
log "What's new:"
log "  1. SOUL.md now references CLAUDE.md + architecture context"
log "  2. GitHub MCP server added (if token provided)"
log "  3. Filesystem MCP server added (repo browsing)"
log "  4. Task dispatch: OpenClaw can queue tasks to Worker fleet"
log "  5. Auto-sync cron: repo pulls every 30 min"
log ""
log "Test it:"
log "  - Send a Telegram message asking about Donut architecture"
log "  - Ask OpenClaw to create a task for the worker fleet"
log "  - Check: docker logs $CONTAINER_NAME --tail 20"
log ""
log "Backups saved to: $BACKUP_DIR"
