#!/bin/bash
#
# setup-networks.sh — Create the restricted Docker network for Isolab
# Run once after Docker is installed.
#

set -euo pipefail

NETWORK_NAME="isolab-packages"

if ! docker network inspect "$NETWORK_NAME" &>/dev/null; then
    docker network create \
        --driver bridge \
        --subnet 172.30.0.0/24 \
        "$NETWORK_NAME"
    echo "isolab: created network '$NETWORK_NAME'"
else
    echo "isolab: network '$NETWORK_NAME' already exists"
fi

# Get bridge interface
BRIDGE_IF=$(docker network inspect "$NETWORK_NAME" --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null)
if [ -z "$BRIDGE_IF" ]; then
    BRIDGE_IF="br-$(docker network inspect "$NETWORK_NAME" --format '{{.Id}}' | cut -c1-12)"
fi

echo "isolab: bridge interface: $BRIDGE_IF"

# Flush existing rules for this bridge
sudo iptables -F DOCKER-USER 2>/dev/null || true

# Allow established connections
sudo iptables -I DOCKER-USER -i "$BRIDGE_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DNS
sudo iptables -I DOCKER-USER -i "$BRIDGE_IF" -p udp --dport 53 -j ACCEPT
sudo iptables -I DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 53 -j ACCEPT

# Allow HTTPS (443) and HTTP (80)
sudo iptables -I DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 443 -j ACCEPT
sudo iptables -I DOCKER-USER -i "$BRIDGE_IF" -p tcp --dport 80 -j ACCEPT

# Block everything else
sudo iptables -A DOCKER-USER -i "$BRIDGE_IF" -j DROP

# Allow return traffic
sudo iptables -A DOCKER-USER -o "$BRIDGE_IF" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

echo ""
echo "isolab: network rules applied"
echo "  Containers on '$NETWORK_NAME' can reach:"
echo "    HTTPS (443) — pypi.org, registry.npmjs.org, github.com"
echo "    HTTP  (80)  — package mirrors"
echo "    DNS   (53)  — name resolution"
echo "  All other outbound traffic is BLOCKED."
echo ""
echo "  For tighter control, point these containers at an AdGuard Home"
echo "  instance configured to only resolve package registry domains."
