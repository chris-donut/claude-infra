#!/bin/bash
# Install CEO Intel pipeline cron job on GCP claude-code-server
# Run this script ON the GCP server (ssh in via Tailscale first)
set -euo pipefail

REPO_DIR="${INTEL_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ENV_FILE="${INTEL_ENV_FILE:-${REPO_DIR}/.env.intel}"
LOG_FILE="/tmp/intel.log"
CRON_MARKER="# donut-ceo-intel"

echo "=== CEO Intel Cron Setup ==="
echo "Repo: $REPO_DIR"
echo "Env:  $ENV_FILE"

# Validate env file exists
if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found"
  echo "Copy .env.intel.example to .env.intel and fill in values"
  exit 1
fi

# Build the cron command
CRON_CMD="0 0 * * * set -a; source ${ENV_FILE}; set +a; cd ${REPO_DIR} && bun run intel >> ${LOG_FILE} 2>&1 ${CRON_MARKER}"

# Check if already installed
if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
  echo "✓ Cron job already installed (skipping)"
  crontab -l | grep "$CRON_MARKER"
  exit 0
fi

# Install
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -
echo "✓ Cron installed: daily at 08:00 HKT (00:00 UTC)"
echo ""
echo "Verify with: crontab -l"
echo "View logs:   tail -f $LOG_FILE"
