#!/bin/bash
#
# setup-networks.sh — Create the restricted Docker network for Isolab
# Run once after Docker is installed.
#

set -euo pipefail

NETWORK_NAME="isolab-packages"
ISOLAB_COMMENT="isolab-packages-rule"

# Check if Docker is accessible
if ! docker info &>/dev/null 2>&1; then
    echo "ERROR: Cannot access Docker daemon"
    echo "Make sure Docker is running and you have permission to use it"
    exit 1
fi

echo "Creating restricted Docker network: $NETWORK_NAME"
echo ""

if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    docker network create \
        --driver bridge \
        --subnet 172.30.0.0/24 \
        "$NETWORK_NAME"
    echo "✓ Created network '$NETWORK_NAME'"
else
    echo "✓ Network '$NETWORK_NAME' already exists"
fi

# Get bridge interface
BRIDGE_IF=$(docker network inspect "$NETWORK_NAME" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null)
if [ -z "$BRIDGE_IF" ]; then
    BRIDGE_IF="br-$(docker network inspect "$NETWORK_NAME" --format '{{.Id}}' | cut -c1-12)"
fi

echo "✓ Bridge interface: $BRIDGE_IF"
echo ""
echo "Configuring iptables rules..."

# Remove only Isolab's rules (identified by comment), leave others intact
sudo iptables -S DOCKER-USER 2>/dev/null | grep -- "--comment ${ISOLAB_COMMENT}" | while read -r rule; do
    # Convert -A to -D for deletion
    sudo iptables ${rule/-A/-D} 2>/dev/null || true
done

# Add rules with comment tag for safe idempotent cleanup
# Order matters: append in sequence so ESTABLISHED is checked first, DROP is last

# Allow established connections
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT

# Allow DNS
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -p udp --dport 53 -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 53 -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT

# Allow HTTPS (443) and HTTP (80)
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 443 -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 80 -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT

# Block everything else from this bridge
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -m comment --comment "$ISOLAB_COMMENT" -j DROP

# Allow return traffic
sudo iptables -A DOCKER-USER -o "$BRIDGE_IF" -m conntrack --ctstate ESTABLISHED,RELATED -m comment --comment "$ISOLAB_COMMENT" -j ACCEPT

echo "✓ Configured iptables rules"
echo ""
echo "Network '$NETWORK_NAME' is now configured with restricted access:"
echo "  ✓ HTTPS (443) — pypi.org, registry.npmjs.org, github.com"
echo "  ✓ HTTP  (80)  — package mirrors"
echo "  ✓ DNS   (53)  — name resolution"
echo "  ✗ All other outbound traffic is BLOCKED"
echo ""
echo "Tip: For tighter control, point containers at an AdGuard Home"
echo "     instance configured to only resolve package registry domains."
echo ""

# ─── DNS filtering setup (for packages mode) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/setup-dns.sh" ]; then
    echo "Setting up DNS filtering for packages mode..."
    echo ""
    bash "${SCRIPT_DIR}/setup-dns.sh"
else
    echo "Note: scripts/setup-dns.sh not found — skipping DNS filter setup."
    echo "  Packages mode (DNS-filtered) won't be available until you run:"
    echo "    sudo isolab setup-dns"
fi
