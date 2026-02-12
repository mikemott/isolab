#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
USER="${SUDO_USER:-$(whoami)}"

echo "isolab: installing dashboard..."

sudo tee /etc/systemd/system/isolab-dashboard.service > /dev/null << EOF
[Unit]
Description=Isolab Dashboard
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
User=${USER}
WorkingDirectory=${REPO_DIR}/dashboard
ExecStart=/usr/bin/python3 ${REPO_DIR}/dashboard/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now isolab-dashboard

echo "  Dashboard running at http://0.0.0.0:8080"
sudo systemctl status isolab-dashboard --no-pager
