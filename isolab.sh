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
#

set -euo pipefail

SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
ISOLAB_IMAGE="${ISOLAB_IMAGE:-isolab:latest}"
CONTAINER_PREFIX="iso-"
SSH_BASE_PORT=2200

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

    if [ ! -f "$SSH_KEY_FILE" ]; then
        echo "error: SSH key not found at $SSH_KEY_FILE"
        echo "Set SSH_KEY_FILE or generate a key with: ssh-keygen -t ed25519"
        exit 1
    fi

    local ssh_pub_key
    ssh_pub_key=$(cat "$SSH_KEY_FILE")

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
        -e SSH_PUBLIC_KEY="$ssh_pub_key" \
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

Network modes:
  --net=none       No network (default). Fully isolated.
  --net=packages   Outbound to package registries only.
  --net=full       Unrestricted network access.

Examples:
  isolab create myproject
  isolab create webdev --net=packages
  isolab ssh myproject
  isolab rm myproject
EOF
        ;;
esac
