#!/bin/bash
# Setup persistent OpenClaw node on GCP claude-code-server
# Run as: sudo bash setup-gcp-node.sh

set -euo pipefail

echo "=== 1. Find openclaw binary ==="
OPENCLAW_BIN=$(sudo -u chrizhuu bash -c 'which openclaw 2>/dev/null') || true
if [ -z "$OPENCLAW_BIN" ]; then
  for p in /usr/local/bin/openclaw /home/chrizhuu/.local/bin/openclaw /usr/bin/openclaw; do
    [ -x "$p" ] && OPENCLAW_BIN="$p" && break
  done
fi
if [ -z "$OPENCLAW_BIN" ]; then
  echo "ERROR: openclaw not found. Install it first."
  exit 1
fi
echo "Found openclaw at: $OPENCLAW_BIN"

echo "=== 2. Detect Node.js path ==="
NODE_BIN_DIR=$(sudo -u chrizhuu bash -c 'dirname "$(which node 2>/dev/null)"' 2>/dev/null) || true
EXTRA_PATH=""
if [ -n "$NODE_BIN_DIR" ] && [ "$NODE_BIN_DIR" != "." ]; then
  EXTRA_PATH=":$NODE_BIN_DIR"
  echo "Found Node.js at: $NODE_BIN_DIR"
else
  echo "WARNING: Node.js not found in chrizhuu's PATH"
fi

echo "=== 3. Create systemd service ==="
OPENCLAW_CONFIG="/home/chrizhuu/.openclaw/config.json"
ENV_LINES="Environment=HOME=/home/chrizhuu"
ENV_LINES="$ENV_LINES\nEnvironment=PATH=/usr/local/bin:/usr/bin:/bin:/home/chrizhuu/.local/bin${EXTRA_PATH}"
if [ -f "$OPENCLAW_CONFIG" ]; then
  ENV_LINES="$ENV_LINES\nEnvironment=OPENCLAW_CONFIG=$OPENCLAW_CONFIG"
fi

cat > /etc/systemd/system/openclaw-node.service << EOF
[Unit]
Description=OpenClaw Node Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=chrizhuu
WorkingDirectory=/home/chrizhuu
ExecStart=$OPENCLAW_BIN node start
Restart=always
RestartSec=10
TimeoutStopSec=30

# OOM protection
OOMScoreAdjust=-500
MemoryMax=512M
MemoryHigh=400M

# Restart limits: 10 attempts per 5 minutes
StartLimitIntervalSec=300
StartLimitBurst=10

# Security hardening
ProtectSystem=full
NoNewPrivileges=true
PrivateTmp=true

$(echo -e "$ENV_LINES")

[Install]
WantedBy=multi-user.target
EOF

echo "=== 4. Setup swap (2GB) if not exists ==="
if ! swapon --show | grep -q '/swapfile'; then
  if [ ! -f /swapfile ]; then
    # fallocate is faster than dd; fallback to dd if unsupported (e.g. btrfs)
    if ! fallocate -l 2G /swapfile 2>/dev/null; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
    fi
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap enabled: 2GB"
else
  echo "Swap already active"
fi

sysctl vm.swappiness=10
grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

echo "=== 5. Configure log rotation ==="
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/openclaw.conf << EOF
[Journal]
SystemMaxUse=200M
SystemMaxFileSize=50M
MaxRetentionSec=7day
EOF
systemctl restart systemd-journald 2>/dev/null || true

echo "=== 6. Enable and start service ==="
systemctl daemon-reload
systemctl enable openclaw-node.service
systemctl restart openclaw-node.service

echo "=== 7. Verify ==="
sleep 3
systemctl status openclaw-node.service --no-pager

echo ""
echo "Done! OpenClaw node will:"
echo "   - Auto-start on boot"
echo "   - Auto-restart on crash (10s delay, max 10 in 5min)"
echo "   - Survive OOM (protected + swap fallback)"
echo "   - Logs rotated (200MB max, 7-day retention)"
echo ""
echo "Commands:"
echo "   systemctl status openclaw-node    # check status"
echo "   journalctl -u openclaw-node -f    # live logs"
echo "   systemctl restart openclaw-node   # manual restart"
