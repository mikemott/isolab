#!/bin/bash
#
# isolab — Disposable, sandboxed environments for LLM agent work
#
# Usage:
#   isolab create <n> [--net=none|packages|full]
#   isolab list
#   isolab ssh <n>
#   isolab stop <n>
#   isolab start <n>
#   isolab rm <n>
#   isolab logs <n>
#   isolab nuke
#   isolab keys add <key-string | key-file>
#   isolab keys list
#   isolab keys rm <index>
#   isolab keys sync [name]
#

set -euo pipefail

ISOLAB_CONFIG_DIR="${ISOLAB_CONFIG_DIR:-$HOME/.config/isolab}"
ISOLAB_KEYS_FILE="${ISOLAB_CONFIG_DIR}/authorized_keys"
ISOLAB_IMAGE="${ISOLAB_IMAGE:-isolab:latest}"
CONTAINER_PREFIX="iso-"
SSH_BASE_PORT=2200

# ─── Key Management ──────────────────────────────────

# Ensure config dir and keys file exist. Auto-imports the server's
# local key on first run so existing workflows keep working.
keys_init() {
    if [ -f "$ISOLAB_KEYS_FILE" ]; then
        return
    fi
    mkdir -p "$ISOLAB_CONFIG_DIR"
    touch "$ISOLAB_KEYS_FILE"
    # Auto-import local key if available
    for f in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        if [ -f "$f" ]; then
            cp "$f" "$ISOLAB_KEYS_FILE"
            echo "isolab: initialized ${ISOLAB_KEYS_FILE} with $(basename "$f")"
            return
        fi
    done
    echo "isolab: created empty ${ISOLAB_KEYS_FILE}"
    echo "  Add keys with: isolab keys add <key-or-file>"
}

# Read all keys from the config file (strips blanks and comments).
keys_read() {
    keys_init
    grep -v '^\s*$' "$ISOLAB_KEYS_FILE" | grep -v '^\s*#' || true
}

cmd_keys() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        add)
            keys_init
            local input="${1:-}"
            if [ -z "$input" ]; then
                echo "Usage: isolab keys add <key-string | path-to-pubkey-file>"
                exit 1
            fi
            local key
            if [ -f "$input" ]; then
                key=$(cat "$input")
            else
                key="$input"
            fi
            # Basic sanity check
            if ! echo "$key" | grep -qE '^ssh-(ed25519|rsa|ecdsa|dss) '; then
                echo "error: doesn't look like an SSH public key"
                echo "  Expected format: ssh-ed25519 AAAA... comment"
                exit 1
            fi
            # Deduplicate
            if grep -qF "$key" "$ISOLAB_KEYS_FILE" 2>/dev/null; then
                echo "isolab: key already present"
                return
            fi
            echo "$key" >> "$ISOLAB_KEYS_FILE"
            echo "isolab: key added"
            echo "  Run 'isolab keys sync' to update running containers."
            ;;
        list|ls)
            keys_init
            local i=0
            echo ""
            while IFS= read -r line; do
                i=$((i + 1))
                local type comment
                type=$(echo "$line" | awk '{print $1}')
                comment=$(echo "$line" | awk '{print $3}')
                local fp
                fp=$(echo "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}') || fp="(unknown)"
                printf "  %d) %s %s  %s\n" "$i" "$type" "$fp" "$comment"
            done < <(keys_read)
            if [ "$i" -eq 0 ]; then
                echo "  (no keys configured)"
                echo "  Add one: isolab keys add ~/.ssh/id_ed25519.pub"
            fi
            echo ""
            ;;
        rm|remove)
            keys_init
            local idx="${1:-}"
            if [ -z "$idx" ] || ! [[ "$idx" =~ ^[0-9]+$ ]]; then
                echo "Usage: isolab keys rm <index>"
                echo "  Run 'isolab keys list' to see indices."
                exit 1
            fi
            local total
            total=$(keys_read | wc -l)
            if [ "$idx" -lt 1 ] || [ "$idx" -gt "$total" ]; then
                echo "error: index out of range (have ${total} keys)"
                exit 1
            fi
            local removed
            removed=$(keys_read | sed -n "${idx}p")
            # Remove that exact line from the file
            grep -vF "$removed" "$ISOLAB_KEYS_FILE" > "${ISOLAB_KEYS_FILE}.tmp" || true
            mv "${ISOLAB_KEYS_FILE}.tmp" "$ISOLAB_KEYS_FILE"
            echo "isolab: removed key ${idx}"
            echo "  Run 'isolab keys sync' to update running containers."
            ;;
        sync)
            keys_init
            local keys
            keys=$(keys_read)
            if [ -z "$keys" ]; then
                echo "error: no keys configured. Add keys first: isolab keys add <key>"
                exit 1
            fi
            local target="${1:-}"
            if [ -n "$target" ]; then
                # Sync one container
                _keys_sync_container "${CONTAINER_PREFIX}${target}" "$keys"
            else
                # Sync all running isolab containers
                local synced=0
                while IFS= read -r cname; do
                    [ -z "$cname" ] && continue
                    _keys_sync_container "$cname" "$keys"
                    synced=$((synced + 1))
                done < <(docker ps --filter "label=isolab=true" --format '{{.Names}}')
                if [ "$synced" -eq 0 ]; then
                    echo "isolab: no running labs to sync"
                fi
            fi
            ;;
        *)
            echo "Usage: isolab keys <add|list|rm|sync>"
            exit 1
            ;;
    esac
}

_keys_sync_container() {
    local cname="$1"
    local keys="$2"
    local name="${cname#${CONTAINER_PREFIX}}"
    echo "$keys" | docker exec -i "$cname" tee /home/sandbox/.ssh/authorized_keys > /dev/null
    docker exec "$cname" chown sandbox:sandbox /home/sandbox/.ssh/authorized_keys
    docker exec "$cname" chmod 600 /home/sandbox/.ssh/authorized_keys
    echo "  ${name}: synced $(echo "$keys" | wc -l) key(s)"
}

get_ssh_port() {
    local name="$1"
    docker inspect --format='{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostPort}}' "${CONTAINER_PREFIX}${name}" 2>/dev/null || echo "N/A"
}

cmd_create() {
    local name="$1"
    local net_mode="${2:---net=none}"
    local container_name="${CONTAINER_PREFIX}${name}"

    if docker ps -a --format '{{.Names}}' | grep -q "^${container_name}$"; then
        echo "error: lab '${name}' already exists"
        exit 1
    fi

    keys_init
    local ssh_pub_keys
    ssh_pub_keys=$(keys_read)
    if [ -z "$ssh_pub_keys" ]; then
        echo "error: no SSH keys configured"
        echo "Add a key with: isolab keys add ~/.ssh/id_ed25519.pub"
        exit 1
    fi

    # Get Tailscale IP (bind to Tailscale interface for secure remote access)
    local bind_ip="127.0.0.1"
    if command -v tailscale &>/dev/null; then
        local ts_ip
        ts_ip=$(tailscale ip -4 2>/dev/null | head -1)
        if [ -n "$ts_ip" ]; then
            bind_ip="$ts_ip"
        fi
    fi

    # Find available port
    local port=$SSH_BASE_PORT
    while ss -tlnH | awk '{print $4}' | grep -q ":${port}$"; do
        port=$((port + 1))
    done

    # Parse network mode
    # Note: --network=none disables all networking including port mapping,
    # so for "none" mode we use the default bridge and block egress via iptables
    local docker_net_args=""
    local net_display=""
    case "$net_mode" in
        --net=none)
            docker_net_args=""
            net_display="ISOLATED"
            ;;
        --net=packages)
            docker_net_args="--network=isolab-packages"
            net_display="PACKAGES"
            ;;
        --net=full)
            docker_net_args=""
            net_display="FULL"
            ;;
        *)
            echo "error: unknown network mode. Use --net=none, --net=packages, or --net=full"
            exit 1
            ;;
    esac

    echo "isolab: creating '${name}'..."
    echo "  Network: ${net_display}"
    if [ "$bind_ip" != "127.0.0.1" ]; then
        echo "  Binding: ${bind_ip} (Tailscale)"
    fi

    docker run -d \
        --name "${container_name}" \
        --runtime=runsc \
        --hostname "${name}" \
        --memory=4g \
        --cpus=2 \
        -p "${bind_ip}:${port}:22" \
        -e SSH_PUBLIC_KEY="$ssh_pub_keys" \
        -e ISOLAB_NET_MODE="$net_display" \
        ${docker_net_args} \
        --label isolab=true \
        --label isolab.name="${name}" \
        --label isolab.net="${net_mode}" \
        --label isolab.created="$(date -Iseconds)" \
        "${ISOLAB_IMAGE}" > /dev/null

    # For "none" mode, block all container egress via iptables
    if [ "$net_mode" = "--net=none" ]; then
        local container_ip
        container_ip=$(docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${container_name}" 2>/dev/null)
        if [ -n "$container_ip" ]; then
            if sudo -n true 2>/dev/null; then
                sudo iptables -I DOCKER-USER -s "$container_ip" -j DROP -m comment --comment "isolab-${name}-block"
                sudo iptables -I DOCKER-USER -s "$container_ip" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "isolab-${name}-block"
            else
                echo "  warning: could not set iptables rules (need sudo)"
                echo "  container has network access — run with sudo for full isolation"
            fi
        fi
    fi

    echo "  Port:    ${port}"
    echo "  tmux:    auto-attaches on login"
    echo "  Logs:    ~/logs/ inside container"
    echo ""
    echo "Connect:"
    if [ "$bind_ip" != "127.0.0.1" ]; then
        echo "  ssh -p ${port} sandbox@${bind_ip}"
    else
        echo "  ssh -p ${port} sandbox@localhost"
        echo "  ssh -p ${port} sandbox@$(hostname)"
    fi
}

cmd_list() {
    local count=0
    echo ""
    printf "  %-16s %-10s %-8s %-12s %-14s\n" "NAME" "STATUS" "PORT" "NETWORK" "UPTIME"
    printf "  %-16s %-10s %-8s %-12s %-14s\n" "────────────────" "──────────" "────────" "────────────" "──────────────"

    while IFS='|' read -r cname status; do
        local name="${cname#${CONTAINER_PREFIX}}"
        local port
        port=$(get_ssh_port "$name")
        local net
        net=$(docker inspect --format='{{index .Config.Labels "isolab.net"}}' "$cname" 2>/dev/null || echo "?")
        net=$(echo "$net" | sed 's/--net=//')
        local short_status
        if echo "$status" | grep -q "Up"; then
            short_status="running"
        else
            short_status="stopped"
        fi
        local uptime
        uptime=$(echo "$status" | sed 's/Up //' | sed 's/Exited.*/stopped/')

        printf "  %-16s %-10s %-8s %-12s %-14s\n" "$name" "$short_status" "$port" "$net" "$uptime"
        count=$((count + 1))
    done < <(docker ps -a --filter "label=isolab=true" --format '{{.Names}}|{{.Status}}')

    if [ "$count" -eq 0 ]; then
        echo "  (no labs)"
    fi
    echo ""
}

cmd_ssh() {
    local name="$1"
    local port
    port=$(get_ssh_port "$name")
    if [ "$port" = "N/A" ]; then
        echo "error: lab '${name}' not found or not running"
        exit 1
    fi
    local bind_ip
    bind_ip=$(docker inspect --format='{{(index (index .NetworkSettings.Ports "22/tcp") 0).HostIp}}' "${CONTAINER_PREFIX}${name}" 2>/dev/null || echo "127.0.0.1")
    if [ -z "$bind_ip" ] || [ "$bind_ip" = "0.0.0.0" ]; then
        bind_ip="127.0.0.1"
    fi
    exec ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$port" sandbox@"$bind_ip"
}

cmd_stop() {
    local name="$1"
    echo "isolab: stopping '${name}'..."
    docker stop "${CONTAINER_PREFIX}${name}" > /dev/null
    echo "  Stopped. tmux sessions preserved — start again to resume."
}

cmd_start() {
    local name="$1"
    echo "isolab: starting '${name}'..."
    docker start "${CONTAINER_PREFIX}${name}" > /dev/null
    local port
    port=$(get_ssh_port "$name")
    echo "  Running on port ${port}."
}

cmd_rm() {
    local name="$1"
    echo "isolab: destroying '${name}'..."
    # Clean up iptables rules for this container (non-fatal if sudo unavailable)
    if sudo -n true 2>/dev/null; then
        sudo iptables -S DOCKER-USER 2>/dev/null | grep -- "isolab-${name}-block" | while read -r rule; do
            sudo iptables ${rule/-A/-D} 2>/dev/null || true
        done
    else
        echo "  warning: skipping iptables cleanup (run with sudo to clean firewall rules)"
    fi
    docker rm -f "${CONTAINER_PREFIX}${name}" > /dev/null
    echo "  Gone."
}

cmd_logs() {
    local name="$1"
    local container_name="${CONTAINER_PREFIX}${name}"
    echo "isolab: session logs for '${name}'"
    echo "────────────────────────────────"
    docker exec "${container_name}" ls -lt /home/sandbox/logs/ 2>/dev/null || echo "  No logs found."
    echo ""
    echo "Tail the latest:"
    echo "  docker exec -it ${container_name} bash -c 'tail -f ~/logs/\$(ls -t ~/logs/ | head -1)'"
}

cmd_nuke() {
    echo "isolab: destroying ALL labs..."
    local count
    count=$(docker ps -a --filter "label=isolab=true" -q | wc -l)
    docker ps -a --filter "label=isolab=true" -q | xargs -r docker rm -f > /dev/null
    echo "  ${count} lab(s) destroyed."
}

cmd_install_proxy() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local install_dir="/usr/local/lib/isolab"
    local conf="/etc/isolab-sshd.conf"
    local user
    user="${SUDO_USER:-$(whoami)}"

    echo "isolab: installing SSH proxy..."

    # Install scripts to root-owned directory
    sudo mkdir -p "$install_dir"
    sudo cp "${script_dir}/scripts/isolab-authkeys" "${install_dir}/isolab-authkeys"
    sudo cp "${script_dir}/scripts/isolab-proxy" "${install_dir}/isolab-proxy"
    sudo tee "${install_dir}/proxy.conf" > /dev/null <<< "ISOLAB_BIN=${script_dir}/isolab.sh"
    sudo chown -R root:root "$install_dir"
    sudo chmod 755 "$install_dir" "${install_dir}/isolab-authkeys" "${install_dir}/isolab-proxy"
    sudo chmod 644 "${install_dir}/proxy.conf"
    echo "  Scripts installed to ${install_dir}"

    # Write sshd config
    sudo tee "$conf" > /dev/null << SSHD_EOF
Port 2222
ListenAddress 0.0.0.0
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthorizedKeysCommand ${install_dir}/isolab-authkeys %u %f %t %k
AuthorizedKeysCommandUser ${user}
AuthorizedKeysFile none
HostKey /etc/ssh/ssh_host_ed25519_key
HostKey /etc/ssh/ssh_host_rsa_key
SyslogFacility AUTH
LogLevel INFO
PermitRootLogin no
AllowUsers ${user}
MaxAuthTries 3
MaxSessions 5
LoginGraceTime 30
PermitTTY yes
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
SSHD_EOF

    # Validate
    if ! sudo /usr/sbin/sshd -t -f "$conf"; then
        echo "  error: sshd config validation failed"
        return 1
    fi
    echo "  Config written to ${conf}"

    # Install and start systemd service
    sudo tee /etc/systemd/system/isolab-sshd.service > /dev/null << SERVICE_EOF
[Unit]
Description=Isolab SSH Proxy (auto-provision containers on connect)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/sbin/sshd -D -f ${conf}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

    sudo systemctl daemon-reload
    sudo systemctl enable isolab-sshd
    sudo systemctl restart isolab-sshd
    echo "  Service started"

    # Open firewall port
    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        sudo ufw allow 2222/tcp comment "isolab proxy" 2>/dev/null || true
        echo "  UFW: port 2222 opened"
    fi

    echo ""
    echo "  SSH proxy running on port 2222"
    echo "  Connect: ssh -p 2222 ${user}@$(hostname)"
}

# ─── Main ────────────────────────────────────────────
case "${1:-help}" in
    create)
        [ -z "${2:-}" ] && echo "Usage: isolab create <name> [--net=none|packages|full]" && exit 1
        cmd_create "$2" "${3:---net=none}"
        ;;
    list|ls)
        cmd_list
        ;;
    ssh)
        [ -z "${2:-}" ] && echo "Usage: isolab ssh <name>" && exit 1
        cmd_ssh "$2"
        ;;
    stop)
        [ -z "${2:-}" ] && echo "Usage: isolab stop <name>" && exit 1
        cmd_stop "$2"
        ;;
    start)
        [ -z "${2:-}" ] && echo "Usage: isolab start <name>" && exit 1
        cmd_start "$2"
        ;;
    rm|remove)
        [ -z "${2:-}" ] && echo "Usage: isolab rm <name>" && exit 1
        cmd_rm "$2"
        ;;
    logs)
        [ -z "${2:-}" ] && echo "Usage: isolab logs <name>" && exit 1
        cmd_logs "$2"
        ;;
    nuke)
        cmd_nuke
        ;;
    keys)
        cmd_keys "${2:-}" "${3:-}"
        ;;
    install-proxy)
        cmd_install_proxy
        ;;
    *)
        cat << 'EOF'
isolab — Disposable, sandboxed environments for LLM agent work

Usage: isolab <command> [args]

Commands:
  create <name> [--net=none|packages|full]   Spin up a new lab
  list                                       List all labs
  ssh <name>                                 SSH in (auto-attaches tmux)
  stop <name>                                Stop (tmux preserved)
  start <name>                               Start a stopped lab
  rm <name>                                  Destroy permanently
  logs <name>                                View session logs
  nuke                                       Destroy ALL labs
  keys add <key|file>                        Add an SSH public key
  keys list                                  List configured keys
  keys rm <index>                            Remove a key by index
  keys sync [name]                           Push keys to running labs
  install-proxy                              Install SSH proxy (port 2222)

Network modes:
  --net=none       No network (default). Fully isolated.
  --net=packages   Outbound to package registries only.
  --net=full       Unrestricted network access.

Examples:
  isolab create myproject
  isolab create webdev --net=packages
  isolab ssh myproject
  isolab keys add ~/.ssh/id_ed25519.pub
  isolab keys sync
  isolab rm myproject
EOF
        ;;
esac
