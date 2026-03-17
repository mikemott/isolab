#!/bin/bash
#
# setup-dns.sh — Install and configure dnsmasq for isolab packages mode
#
# Provides DNS-based domain filtering: only allowlisted domains resolve.
# Containers in "packages" mode have their DNS queries redirected here
# via iptables NAT PREROUTING rules.
#
# Run once: sudo bash scripts/setup-dns.sh
#

set -euo pipefail

_home="${SUDO_USER:+/home/${SUDO_USER}}"
_home="${_home:-${HOME:-/root}}"
ISOLAB_CONFIG_DIR="${ISOLAB_CONFIG_DIR:-${_home}/.config/isolab}"
ALLOWLIST_FILE="${ISOLAB_CONFIG_DIR}/packages-allowlist.conf"
DNSMASQ_CONF_DIR="/etc/isolab"
DNSMASQ_CONF="${DNSMASQ_CONF_DIR}/dnsmasq.conf"
DNSMASQ_GENERATED="${DNSMASQ_CONF_DIR}/allowlist.conf"
GEN_SCRIPT="/usr/local/lib/isolab/gen-dns-allowlist"

echo "isolab: setting up DNS filtering for packages mode"
echo ""

# ─── Install dnsmasq ─────────────────────────────────

if ! command -v dnsmasq &>/dev/null; then
    echo "Installing dnsmasq..."
    apt-get update -qq
    apt-get install -y -qq dnsmasq > /dev/null
    # Disable the default dnsmasq service (we run our own)
    systemctl stop dnsmasq 2>/dev/null || true
    systemctl disable dnsmasq 2>/dev/null || true
    echo "  dnsmasq installed"
else
    echo "  dnsmasq already installed"
fi

# ─── Discover Docker bridge gateway ──────────────────

BRIDGE_GW=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
echo "  Docker bridge gateway: ${BRIDGE_GW}"

# ─── Create default allowlist ────────────────────────

mkdir -p "$ISOLAB_CONFIG_DIR"

if [ ! -f "$ALLOWLIST_FILE" ]; then
    cat > "$ALLOWLIST_FILE" << 'ALLOWLIST'
# Isolab packages-mode DNS allowlist
# One domain per line. Subdomains are NOT automatically included.
# Edit this file, then run: isolab dns-reload

# Python
pypi.org
files.pythonhosted.org

# npm / Node
registry.npmjs.org
nodejs.org
yarnpkg.com

# System packages
archive.ubuntu.com
security.ubuntu.com
deb.debian.org

# Go
proxy.golang.org
sum.golang.org
storage.googleapis.com

# Rust
crates.io
static.crates.io
rustup.rs
static.rust-lang.org

# Ruby
rubygems.org

# GitHub (for git clone, releases)
github.com
codeload.github.com
objects.githubusercontent.com
raw.githubusercontent.com

# AI APIs
api.anthropic.com
api.openai.com
ALLOWLIST
    # Fix ownership if running as sudo
    if [ -n "${SUDO_USER:-}" ]; then
        chown "${SUDO_USER}:${SUDO_USER}" "$ALLOWLIST_FILE"
    fi
    echo "  Created default allowlist: ${ALLOWLIST_FILE}"
else
    echo "  Allowlist exists: ${ALLOWLIST_FILE}"
fi

# ─── Create converter script ────────────────────────

mkdir -p "$(dirname "$GEN_SCRIPT")"

cat > "$GEN_SCRIPT" << 'GENSCRIPT'
#!/bin/bash
# Generate dnsmasq allowlist from isolab packages-allowlist.conf
# Reads domain-per-line file, outputs dnsmasq server= directives

set -euo pipefail

ISOLAB_CONFIG_DIR="${ISOLAB_CONFIG_DIR:-/home/${SUDO_USER:-root}/.config/isolab}"
ALLOWLIST="${ISOLAB_CONFIG_DIR}/packages-allowlist.conf"
OUTPUT="/etc/isolab/allowlist.conf"

if [ ! -f "$ALLOWLIST" ]; then
    echo "# No allowlist found" > "$OUTPUT"
    exit 0
fi

{
    echo "# Auto-generated from ${ALLOWLIST}"
    echo "# Do not edit — modify the allowlist and run: isolab dns-reload"
    echo ""
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [ -z "$line" ] && continue
        echo "server=/${line}/8.8.8.8"
    done < "$ALLOWLIST"
} > "$OUTPUT"
GENSCRIPT

chmod 755 "$GEN_SCRIPT"
echo "  Converter script: ${GEN_SCRIPT}"

# ─── Fix SUDO_USER in converter for this system ─────

# Bake the actual config dir path into the converter
sed -i "s|/home/\${SUDO_USER:-root}/.config/isolab|${ISOLAB_CONFIG_DIR}|" "$GEN_SCRIPT"

# ─── Generate initial allowlist ──────────────────────

"$GEN_SCRIPT"
echo "  Generated dnsmasq allowlist"

# ─── Create dnsmasq config ──────────────────────────

mkdir -p "$DNSMASQ_CONF_DIR"

cat > "$DNSMASQ_CONF" << DNSCONF
# Isolab DNS filter for packages mode
# Listens on Docker bridge gateway, port 5354
# Only resolves domains listed in the allowlist

no-resolv
no-hosts
listen-address=${BRIDGE_GW}
port=5354
bind-interfaces

# Default: refuse all queries (NXDOMAIN)
address=/#/

# Include generated allowlist (server= directives for allowed domains)
conf-file=${DNSMASQ_GENERATED}

# Logging (optional — comment out to reduce noise)
# log-queries
# log-facility=/var/log/isolab-dns.log
DNSCONF

echo "  dnsmasq config: ${DNSMASQ_CONF}"

# ─── Create systemd service ─────────────────────────

cat > /etc/systemd/system/isolab-dns.service << SVCEOF
[Unit]
Description=Isolab DNS filter (dnsmasq for packages mode)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStartPre=${GEN_SCRIPT}
ExecStart=/usr/sbin/dnsmasq --no-daemon --conf-file=${DNSMASQ_CONF}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable isolab-dns
systemctl restart isolab-dns

echo ""
echo "  isolab-dns service started"
echo ""
echo "DNS filtering is ready for packages mode:"
echo "  Allowlist:  ${ALLOWLIST_FILE}"
echo "  Listening:  ${BRIDGE_GW}:5354"
echo "  Edit & reload: isolab dns-reload"
