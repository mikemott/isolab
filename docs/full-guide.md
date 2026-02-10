# Isolab — Full Setup Guide

## Bare Metal → Disposable Labs for Safe LLM Agent Work

> **Automated setup available:** For a one-command install, run `./setup.sh --full` from the repo root. This guide is for users who prefer to understand and execute each step manually.

This guide walks through setting up a dedicated Isolab host from scratch: Ubuntu install, networking, Docker, gVisor, the container image, CLI, and dashboard.

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Your Main Machine (Mac/PC)                     │
│  SSH / Tailscale → isolab host                  │
└──────────────┬──────────────────────────────────┘
               │ Tailscale / Cloudflare Tunnel
               ▼
┌─────────────────────────────────────────────────┐
│  Isolab Host (Spare PC)                         │
│  Ubuntu Server 24.04 + Docker + gVisor          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐        │
│  │ iso-proj1│ │ iso-proj2│ │ iso-proj3│  ...    │
│  │ no net   │ │ pypi-only│ │ full net │        │
│  │ gVisor   │ │ gVisor   │ │ gVisor   │        │
│  └──────────┘ └──────────┘ └──────────┘        │
│  ┌──────────────────────────────────────┐       │
│  │  Dashboard (port 8080 via Tailscale) │       │
│  └──────────────────────────────────────┘       │
└─────────────────────────────────────────────────┘
```

**Threat model:** An LLM agent running inside a container could attempt to exfiltrate secrets, SSH keys, or local files. By running agents on a physically separate host inside network-isolated, gVisor-sandboxed containers, even a fully compromised container has no path to your data.

---

## Part 1: Base OS

### 1.1 Install Ubuntu Server 24.04 LTS

Download from https://ubuntu.com/download/server. During install: choose minimal server, enable OpenSSH, set a strong password.

### 1.2 Post-Install

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git htop tmux jq \
  apt-transport-https ca-certificates gnupg lsb-release \
  python3 python3-pip python3-venv ufw

sudo timedatectl set-timezone America/New_York

# Automatic security updates
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 1.3 Harden

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow in on tailscale0
sudo ufw enable

# After setting up SSH keys:
sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

---

## Part 2: Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh
tailscale status
```

Now SSH from your main machine: `ssh user@isolab-host`

---

## Part 3: Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in
docker run --rm hello-world
```

---

## Part 4: gVisor

```bash
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | \
  sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

sudo apt update && sudo apt install -y runsc
sudo runsc install
sudo systemctl restart docker

# Verify
docker run --rm --runtime=runsc hello-world
```

---

## Part 5: Build & Install Isolab

```bash
git clone https://github.com/YOUR_USERNAME/isolab.git
cd isolab

# Build the image
docker build -t isolab:latest ./image

# Set up restricted network
sudo ./scripts/setup-networks.sh

# Install CLI
chmod +x isolab.sh
sudo ln -sf $(pwd)/isolab.sh /usr/local/bin/isolab
```

---

## Part 6: Dashboard

```bash
pip install flask docker --break-system-packages
python3 dashboard/app.py
```

Access: `http://isolab-host:8080`

### Run as a Service

```bash
sudo tee /etc/systemd/system/isolab-dashboard.service << EOF
[Unit]
Description=Isolab Dashboard
After=docker.service
Requires=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)/dashboard
ExecStart=/usr/bin/python3 $(pwd)/dashboard/app.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable isolab-dashboard
sudo systemctl start isolab-dashboard
```

---

## Part 7: Day-to-Day Workflow

```bash
# Create an isolated lab
isolab create agent-work

# SSH in (auto-attaches tmux)
isolab ssh agent-work

# Inside: run your agent, do work...
# Ctrl-b d to detach tmux (session persists)
# SSH back in later — picks up where you left off

# When done
isolab rm agent-work
```

### Tips

1. **Default to `--net=none`** — escalate to `--net=packages` only to install dependencies.

2. **Never mount host volumes** — copy files with scp:
   ```bash
   scp -P 2200 myfile.txt sandbox@isolab-host:~/workspace/
   scp -P 2200 sandbox@isolab-host:~/workspace/output.txt .
   ```

3. **API keys as env vars** — pass at creation time, never bake into images.

4. **Snapshot good environments:**
   ```bash
   docker commit iso-myproject isolab:myproject-snapshot
   ```

5. **Resource limits** — edit `--memory` and `--cpus` in `isolab.sh` (defaults: 4GB, 2 CPUs).

---

## Security Checklist

- [ ] SSH key auth only on host
- [ ] UFW enabled, only SSH + Tailscale
- [ ] gVisor runtime for all lab containers
- [ ] Default network mode is `--net=none`
- [ ] No host volumes mounted
- [ ] API keys as env vars only
- [ ] Host physically separate from dev machine
- [ ] Tailscale ACLs configured
- [ ] Automatic security updates enabled
- [ ] Dashboard only reachable via Tailscale

---

## Troubleshooting

**gVisor won't start:**
```bash
docker info | grep -i runtime    # should show runsc
sudo runsc --version
```

**Can't SSH into a lab:**
```bash
docker ps --filter "label=isolab=true"
docker logs iso-<n>
docker port iso-<n> 22
```

**Network not blocked:**
```bash
sudo iptables -L DOCKER-USER -v -n
docker exec iso-<n> curl -s https://example.com  # should fail for --net=none
```
