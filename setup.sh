#!/bin/bash
#
# setup.sh — Interactive setup wizard for Isolab
#
# Usage:
#   ./setup.sh              Interactive wizard (default when TTY)
#   ./setup.sh --auto       Non-interactive with sensible defaults
#   ./setup.sh --help       Show usage
#

set -euo pipefail

# ── Constants & Colors (Amber Retro Palette) ────────────

AMBER='\033[38;5;214m'
DIM_AMBER='\033[38;5;136m'
BRIGHT_AMBER='\033[38;5;220m'
GREEN='\033[38;5;78m'
RED='\033[38;5;196m'
DIM='\033[38;5;240m'
WHITE='\033[38;5;255m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTERACTIVE=false
TERM_SAVED=""

# Wizard state
SETUP_MODE=""  # "quick" or "full"
declare -a SELECTED_OPTIONS=()
declare -a OPTION_LABELS=()
declare -a OPTION_DEFAULTS=()
declare -a OPTION_KEYS=()
NEEDS_RELOGIN=false
NEEDS_TAILSCALE_AUTH=false

# ── Terminal Helpers ────────────────────────────────────

cleanup() {
    # Restore terminal state
    if [ -n "$TERM_SAVED" ]; then
        stty "$TERM_SAVED" 2>/dev/null || true
    fi
    tput cnorm 2>/dev/null || true  # show cursor
    echo -e "${NC}"
}

trap cleanup EXIT INT TERM

hide_cursor() { tput civis 2>/dev/null || true; }
show_cursor() { tput cnorm 2>/dev/null || true; }

get_term_width() {
    local w
    w=$(tput cols 2>/dev/null) || w=80
    echo "$w"
}

get_term_height() {
    local h
    h=$(tput lines 2>/dev/null) || h=24
    echo "$h"
}

clear_screen() {
    printf '\033[2J\033[H'
}

print_logo() {
    local compact="${1:-false}"
    echo -e "${AMBER}${BOLD}"
    echo "       ╦╔═╗╔═╗╦  ╔═╗╔╗ "
    echo "       ║╚═╗║ ║║  ╠═╣╠╩╗"
    echo "       ╩╚═╝╚═╝╩═╝╩ ╩╚═╝"
    echo -e "${NC}"
    if [ "$compact" = "false" ]; then
        echo -e "  ${DIM_AMBER}  ⬡ Disposable sandboxed environments${NC}"
        echo -e "  ${DIM_AMBER}    for LLM agent work${NC}"
    fi
}

move_to() {
    local row=$1 col=$2
    printf '\033[%d;%dH' "$row" "$col"
}

# ── Box Drawing ─────────────────────────────────────────

draw_box() {
    local width=$1
    local title="${2:-}"
    local color="${3:-$DIM_AMBER}"

    echo -ne "${color}"
    # Top border
    echo -n "  ╭"
    if [ -n "$title" ]; then
        # Strip ANSI codes to get actual visible length
        local stripped
        stripped=$(echo -e "$title" | sed 's/\x1b\[[0-9;]*m//g')
        local tlen=${#stripped}
        local padding=$((width - tlen - 4))
        if [ "$padding" -lt 0 ]; then padding=0; fi
        echo -n "─ ${NC}${AMBER}${BOLD}${title}${NC}${color} "
        printf '─%.0s' $(seq 1 "$padding")
    else
        printf '─%.0s' $(seq 1 $((width - 2)))
    fi
    echo "╮"
    echo -ne "${NC}"
}

draw_box_line() {
    local width=$1
    local content="$2"
    local color="${3:-$DIM_AMBER}"
    local stripped
    stripped=$(echo -e "$content" | sed 's/\x1b\[[0-9;]*m//g')
    local clen=${#stripped}
    local padding=$((width - clen - 4))
    if [ "$padding" -lt 0 ]; then padding=0; fi

    echo -ne "${color}  │${NC} ${content}"
    printf ' %.0s' $(seq 1 "$padding")
    echo -e "${color} │${NC}"
}

draw_box_empty() {
    local width=$1
    local color="${2:-$DIM_AMBER}"
    local inner=$((width - 4))
    echo -ne "${color}  │"
    printf ' %.0s' $(seq 1 $((inner + 2)))
    echo -e "│${NC}"
}

draw_box_separator() {
    local width=$1
    local color="${2:-$DIM_AMBER}"
    echo -ne "${color}  ├"
    printf '─%.0s' $(seq 1 $((width - 2)))
    echo -e "┤${NC}"
}

draw_box_bottom() {
    local width=$1
    local color="${2:-$DIM_AMBER}"
    echo -ne "${color}  ╰"
    printf '─%.0s' $(seq 1 $((width - 2)))
    echo -e "╯${NC}"
}

# ── Key Reading ─────────────────────────────────────────

read_key() {
    local key
    IFS= read -rsn1 key 2>/dev/null || return 1
    if [[ "$key" == $'\x1b' ]]; then
        local seq=""
        IFS= read -rsn1 -t 0.1 seq 2>/dev/null || true
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.1 seq 2>/dev/null || true
            case "$seq" in
                A) echo "UP"; return;;
                B) echo "DOWN"; return;;
                C) echo "RIGHT"; return;;
                D) echo "LEFT"; return;;
            esac
        fi
        echo "ESC"
        return
    fi
    case "$key" in
        "") echo "ENTER"; return;;
        " ") echo "SPACE"; return;;
        q|Q) echo "QUIT"; return;;
        k|K) echo "UP"; return;;
        j|J) echo "DOWN"; return;;
    esac
    echo "$key"
}

# ── UI Components ───────────────────────────────────────

# Single-select menu with arrow keys
# Args: prompt, options (newline-separated), descriptions (newline-separated)
# Returns: index (0-based) in global SELECT_RESULT
SELECT_RESULT=0

select_menu() {
    local prompt="$1"
    shift
    local -a options=()
    local -a descs=()
    while [ $# -gt 0 ]; do
        options+=("$1")
        descs+=("${2:-}")
        shift 2 || shift 1
    done

    local current=0
    local count=${#options[@]}

    hide_cursor
    while true; do
        # Render
        echo ""
        echo -e "  ${AMBER}${BOLD}${prompt}${NC}"
        echo ""

        for i in $(seq 0 $((count - 1))); do
            if [ "$i" -eq "$current" ]; then
                echo -e "    ${AMBER}${BOLD}▸ ${options[$i]}${NC}"
                if [ -n "${descs[$i]:-}" ]; then
                    echo -e "      ${DIM}${descs[$i]}${NC}"
                fi
            else
                echo -e "    ${DIM}  ${options[$i]}${NC}"
                if [ -n "${descs[$i]:-}" ]; then
                    echo -e "      ${DIM}${descs[$i]}${NC}"
                fi
            fi
        done

        echo ""
        echo -e "  ${DIM}↑↓ navigate  ⏎ select${NC}"

        local key
        key=$(read_key)
        case "$key" in
            UP)
                current=$(( (current - 1 + count) % count ))
                ;;
            DOWN)
                current=$(( (current + 1) % count ))
                ;;
            ENTER)
                SELECT_RESULT=$current
                show_cursor
                return
                ;;
            QUIT)
                show_cursor
                echo ""
                echo -e "  ${DIM}Aborted.${NC}"
                exit 0
                ;;
        esac

        # Move cursor up to redraw
        # Count: empty + prompt + empty + options + empty + footer = 5 base lines
        local lines_to_clear=5
        for i in $(seq 0 $((count - 1))); do
            lines_to_clear=$((lines_to_clear + 1))
            if [ -n "${descs[$i]:-}" ]; then
                lines_to_clear=$((lines_to_clear + 1))
            fi
        done
        # Move cursor up and clear to end of screen
        printf '\033[%dA' "$lines_to_clear"
        printf '\033[J'
    done
}

# Multi-select checkbox menu
# Sets CHECKBOX_RESULT as array of 0/1 values
declare -a CHECKBOX_RESULT=()

checkbox_menu() {
    local prompt="$1"
    shift
    local -a labels=()
    local -a states=()
    while [ $# -gt 0 ]; do
        labels+=("$1")
        states+=("${2:-0}")
        shift 2
    done

    local current=0
    local count=${#labels[@]}

    hide_cursor
    while true; do
        echo ""
        echo -e "  ${AMBER}${BOLD}${prompt}${NC}"
        echo ""

        for i in $(seq 0 $((count - 1))); do
            local check=" "
            if [ "${states[$i]}" -eq 1 ]; then
                check="${GREEN}✓${NC}"
            fi

            if [ "$i" -eq "$current" ]; then
                echo -e "    ${AMBER}▸${NC} [${check}] ${WHITE}${labels[$i]}${NC}"
            else
                echo -e "      [${check}] ${DIM}${labels[$i]}${NC}"
            fi
        done

        echo ""
        echo -e "  ${DIM}↑↓ navigate  ␣ toggle  ⏎ confirm${NC}"

        local key
        key=$(read_key)
        case "$key" in
            UP)
                current=$(( (current - 1 + count) % count ))
                ;;
            DOWN)
                current=$(( (current + 1) % count ))
                ;;
            SPACE)
                if [ "${states[$current]}" -eq 1 ]; then
                    states[$current]=0
                else
                    states[$current]=1
                fi
                ;;
            ENTER)
                CHECKBOX_RESULT=("${states[@]}")
                show_cursor
                return
                ;;
            QUIT)
                show_cursor
                echo ""
                echo -e "  ${DIM}Aborted.${NC}"
                exit 0
                ;;
        esac

        # Move cursor up to redraw
        # Count: empty + prompt + empty + options + empty + footer
        local lines_to_clear=$((count + 5))
        printf '\033[%dA' "$lines_to_clear"
        printf '\033[J'
    done
}

# Spinner — runs in background
SPINNER_PID=""

spinner_start() {
    local msg="$1"
    local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    local i=0

    (
        while true; do
            printf '\r  %b%s%b %s' "$AMBER" "${frames[$i]}" "$NC" "$msg"
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null || true
}

spinner_stop() {
    local status=$1
    local msg="$2"

    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null || true
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
    fi

    printf '\r\033[K'
    if [ "$status" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} ${msg}"
    else
        echo -e "  ${RED}✗${NC} ${msg}"
    fi
}

wait_for_enter() {
    local msg="${1:-Press Enter to continue}"
    echo ""
    echo -e "  ${DIM}${msg}${NC}"
    read -rs
}

# ── Detection Functions ─────────────────────────────────

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$PRETTY_NAME"
    elif [ "$(uname)" = "Darwin" ]; then
        echo "macOS $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
    else
        echo "Unknown ($(uname -s))"
    fi
}

detect_arch() {
    uname -m
}

detect_docker() {
    if command -v docker &>/dev/null; then
        local ver
        ver=$(docker --version 2>/dev/null | sed 's/Docker version //' | cut -d',' -f1)
        echo "installed ($ver)"
        return 0
    fi
    echo "not installed"
    return 1
}

detect_gvisor() {
    if command -v runsc &>/dev/null; then
        local ver
        ver=$(runsc --version 2>&1 | head -1 | sed 's/runsc version //')
        echo "installed ($ver)"
        return 0
    fi
    echo "not installed"
    return 1
}

detect_ssh_key() {
    if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
        echo "found (ed25519)"
        return 0
    elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
        echo "found (RSA)"
        return 0
    fi
    echo "not found"
    return 1
}

detect_isolab_image() {
    if command -v docker &>/dev/null && docker image inspect isolab:latest &>/dev/null 2>&1; then
        echo "built"
        return 0
    fi
    echo "not built"
    return 1
}

# ── Screen Functions ────────────────────────────────────

screen_welcome() {
    clear_screen

    local w
    w=$(get_term_width)
    local box_w=56
    if [ "$w" -lt 60 ]; then box_w=$((w - 4)); fi

    echo ""
    print_logo
    echo ""

    draw_box "$box_w" "Setup Wizard"
    draw_box_empty "$box_w"
    draw_box_line "$box_w" "This wizard will guide you through installing"
    draw_box_line "$box_w" "and configuring Isolab on this machine."
    draw_box_empty "$box_w"
    draw_box_line "$box_w" "${DIM}Includes: Docker, gVisor, container image,"
    draw_box_line "$box_w" "${DIM}restricted networking, and CLI tools."
    draw_box_empty "$box_w"
    draw_box_bottom "$box_w"

    wait_for_enter
}

screen_detect() {
    clear_screen

    echo ""
    echo -e "  ${AMBER}${BOLD}Environment Detection${NC}"
    echo -e "  ${DIM_AMBER}Scanning your system...${NC}"
    echo ""

    local w=52

    draw_box "$w" "System"

    # OS
    local os
    os=$(detect_os)
    draw_box_line "$w" "${WHITE}OS${NC}           ${os}"

    # Architecture
    local arch
    arch=$(detect_arch)
    local arch_icon="${GREEN}✓${NC}"
    if [ "$arch" != "x86_64" ] && [ "$arch" != "aarch64" ]; then
        arch_icon="${RED}⚠${NC}"
    fi
    draw_box_line "$w" "${WHITE}Arch${NC}         ${arch} ${arch_icon}"

    draw_box_separator "$w"

    # Docker
    local docker_status docker_icon
    if docker_status=$(detect_docker); then
        docker_icon="${GREEN}✓${NC}"
    else
        docker_icon="${DIM}○${NC}"
    fi
    draw_box_line "$w" "${WHITE}Docker${NC}       ${docker_status} ${docker_icon}"

    # gVisor
    local gvisor_status gvisor_icon
    if gvisor_status=$(detect_gvisor); then
        gvisor_icon="${GREEN}✓${NC}"
    else
        gvisor_icon="${DIM}○${NC}"
    fi
    draw_box_line "$w" "${WHITE}gVisor${NC}       ${gvisor_status} ${gvisor_icon}"

    # Isolab image
    local image_status image_icon
    if image_status=$(detect_isolab_image); then
        image_icon="${GREEN}✓${NC}"
    else
        image_icon="${DIM}○${NC}"
    fi
    draw_box_line "$w" "${WHITE}Image${NC}        ${image_status} ${image_icon}"

    draw_box_separator "$w"

    # SSH key
    local ssh_status ssh_icon
    if ssh_status=$(detect_ssh_key); then
        ssh_icon="${GREEN}✓${NC}"
    else
        ssh_icon="${RED}⚠${NC}"
    fi
    draw_box_line "$w" "${WHITE}SSH key${NC}      ${ssh_status} ${ssh_icon}"

    draw_box_empty "$w"
    draw_box_bottom "$w"

    # Platform warning
    if [ "$(uname)" = "Darwin" ]; then
        echo ""
        echo -e "  ${RED}${BOLD}⚠  macOS detected${NC}"
        echo -e "  ${DIM}Isolab is designed for Ubuntu/Debian Linux hosts."
        echo -e "  ${DIM}Some features (gVisor, iptables) won't work on macOS."
        echo -e "  ${DIM}You can still explore the setup flow.${NC}"
    fi

    if [ "$arch" != "x86_64" ] && [ "$arch" != "aarch64" ]; then
        echo ""
        echo -e "  ${RED}⚠${NC}  ${DIM}gVisor may not support ${arch}${NC}"
    fi

    if ! detect_ssh_key &>/dev/null; then
        echo ""
        echo -e "  ${RED}⚠${NC}  ${DIM}No SSH key found — you'll need one to access containers${NC}"
        echo -e "  ${DIM}    Generate with: ${WHITE}ssh-keygen -t ed25519${NC}"
    fi

    wait_for_enter
}

screen_mode() {
    clear_screen

    echo ""
    echo -e "  ${AMBER}${BOLD}Setup Mode${NC}"
    echo -e "  ${DIM_AMBER}Choose what to install${NC}"

    select_menu "Select a setup mode:" \
        "Quick Setup" "Docker + gVisor + Isolab (already have a hardened host)" \
        "Full Setup" "System hardening + Tailscale + firewall + Docker + gVisor + Isolab"

    if [ "$SELECT_RESULT" -eq 0 ]; then
        SETUP_MODE="quick"
    else
        SETUP_MODE="full"
    fi
}

screen_options() {
    clear_screen

    echo ""
    echo -e "  ${AMBER}${BOLD}Options${NC}"
    echo -e "  ${DIM_AMBER}Toggle features to install (${SETUP_MODE} mode)${NC}"

    OPTION_LABELS=()
    OPTION_DEFAULTS=()
    OPTION_KEYS=()

    if [ "$SETUP_MODE" = "full" ]; then
        OPTION_LABELS+=("System update (apt upgrade)")
        OPTION_DEFAULTS+=(1)
        OPTION_KEYS+=("system_update")

        OPTION_LABELS+=("UFW firewall")
        OPTION_DEFAULTS+=(1)
        OPTION_KEYS+=("ufw")

        OPTION_LABELS+=("SSH hardening (disable passwords)")
        OPTION_DEFAULTS+=(0)
        OPTION_KEYS+=("ssh_harden")

        OPTION_LABELS+=("Tailscale")
        OPTION_DEFAULTS+=(0)
        OPTION_KEYS+=("tailscale")

        OPTION_LABELS+=("Automatic security updates")
        OPTION_DEFAULTS+=(1)
        OPTION_KEYS+=("unattended")
    fi

    OPTION_LABELS+=("Build Isolab image")
    OPTION_DEFAULTS+=(1)
    OPTION_KEYS+=("build_image")

    OPTION_LABELS+=("Setup restricted network")
    OPTION_DEFAULTS+=(1)
    OPTION_KEYS+=("setup_network")

    OPTION_LABELS+=("Install CLI to /usr/local/bin")
    OPTION_DEFAULTS+=(1)
    OPTION_KEYS+=("install_cli")

    OPTION_LABELS+=("Install web dashboard")
    OPTION_DEFAULTS+=(0)
    OPTION_KEYS+=("dashboard")

    # Build args for checkbox_menu
    local args=()
    for i in $(seq 0 $((${#OPTION_LABELS[@]} - 1))); do
        args+=("${OPTION_LABELS[$i]}" "${OPTION_DEFAULTS[$i]}")
    done

    checkbox_menu "Select components:" "${args[@]}"

    SELECTED_OPTIONS=("${CHECKBOX_RESULT[@]}")
}

is_selected() {
    local key=$1
    for i in $(seq 0 $((${#OPTION_KEYS[@]} - 1))); do
        if [ "${OPTION_KEYS[$i]}" = "$key" ] && [ "${SELECTED_OPTIONS[$i]}" -eq 1 ]; then
            return 0
        fi
    done
    return 1
}

screen_review() {
    clear_screen

    echo ""
    echo -e "  ${AMBER}${BOLD}Review${NC}"
    echo -e "  ${DIM_AMBER}Confirm your selections${NC}"
    echo ""

    local w=52

    local mode_label="Quick Setup"
    if [ "$SETUP_MODE" = "full" ]; then
        mode_label="Full Setup"
    fi

    draw_box "$w" "Installation Plan"
    draw_box_line "$w" "${WHITE}Mode:${NC} ${AMBER}${mode_label}${NC}"
    draw_box_separator "$w"

    local step_count=0
    # Always: preflight + system packages + docker + gvisor + verify
    step_count=4

    for i in $(seq 0 $((${#OPTION_KEYS[@]} - 1))); do
        if [ "${SELECTED_OPTIONS[$i]}" -eq 1 ]; then
            draw_box_line "$w" "${GREEN}✓${NC} ${OPTION_LABELS[$i]}"
            step_count=$((step_count + 1))
        else
            draw_box_line "$w" "${DIM}○ ${OPTION_LABELS[$i]}${NC}"
        fi
    done

    draw_box_separator "$w"
    draw_box_line "$w" "${DIM}+ System packages, Docker, gVisor (always)${NC}"
    draw_box_line "$w" "${DIM}  Total: ~${step_count} steps${NC}"
    draw_box_empty "$w"
    draw_box_bottom "$w"

    echo ""
    echo -e "  ${DIM}Press ${WHITE}Enter${DIM} to begin installation, ${WHITE}q${DIM} to abort${NC}"

    while true; do
        local key
        key=$(read_key)
        case "$key" in
            ENTER) return 0;;
            QUIT)
                echo ""
                echo -e "  ${DIM}Aborted.${NC}"
                exit 0
                ;;
        esac
    done
}

# ── Installation Functions ──────────────────────────────

run_step() {
    local label="$1"
    shift
    local cmd="$*"

    spinner_start "$label"
    local exit_code=0
    eval "$cmd" >> /tmp/isolab-setup.log 2>&1 || exit_code=$?
    spinner_stop "$exit_code" "$label"
    return "$exit_code"
}

# Run step with live output (for long operations like docker build)
run_step_verbose() {
    local label="$1"
    shift
    local cmd="$*"
    local description="${STEP_DESCRIPTIONS[$label]:-}"

    echo ""
    echo -e "  ${AMBER}${BOLD}${label}${NC}"
    if [ -n "$description" ]; then
        echo -e "  ${DIM}${description}${NC}"
    fi
    echo ""

    local exit_code=0
    # Show output but also log it
    eval "$cmd" 2>&1 | tee -a /tmp/isolab-setup.log || exit_code=$?

    echo ""
    if [ "$exit_code" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} ${label}"
    else
        echo -e "  ${RED}✗${NC} ${label} (exit code: ${exit_code})"
        echo -e "  ${DIM}Check /tmp/isolab-setup.log for details${NC}"
    fi
    return "$exit_code"
}

# Declare associative array for step descriptions
declare -A STEP_DESCRIPTIONS=(
    ["System packages"]="Installing curl, wget, git, jq"
    ["Hardening packages"]="Installing security tools (ufw, unattended-upgrades)"
    ["System update"]="Running apt upgrade (this may take a while)"
    ["UFW firewall"]="Configuring firewall: deny incoming, allow SSH"
    ["SSH hardening"]="Disabling password authentication"
    ["Tailscale"]="Installing Tailscale for secure remote access"
    ["Automatic security updates"]="Enabling unattended-upgrades"
    ["Docker"]="Installing Docker engine and adding user to docker group"
    ["gVisor"]="Installing gVisor (runsc) for enhanced container isolation"
    ["Build Isolab image"]="Building container image with dev tools (Python, Node.js, etc). This takes 3-5 minutes..."
    ["Restricted network"]="Creating Docker network with iptables rules for package-only access"
    ["Install CLI"]="Symlinking isolab command to /usr/local/bin"
    ["Web dashboard"]="Installing Flask and Docker Python packages"
)

do_preflight() {
    # Root check
    if [ "$(id -u)" -eq 0 ]; then
        echo -e "  ${RED}✗${NC} Do not run as root. Use your normal user (sudo is used where needed)."
        exit 1
    fi

    # sudo check
    if ! command -v sudo &>/dev/null; then
        echo -e "  ${RED}✗${NC} sudo is required but not installed."
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        echo ""
        echo -e "  ${AMBER}sudo access required${NC} — you may be prompted for your password."
        sudo true || exit 1
    fi
}

step_system_packages() {
    local packages=(curl wget git jq)
    local missing=()
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then
        return 0
    fi
    sudo apt-get update -qq
    # Suppress needrestart interactive prompts
    sudo NEEDRESTART_MODE=a apt-get install -y -qq "${missing[@]}"
}

step_hardening_packages() {
    local packages=(htop tmux python3 python3-pip python3-venv ufw unattended-upgrades)
    local missing=()
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -eq 0 ]; then return 0; fi
    sudo NEEDRESTART_MODE=a apt-get install -y -qq "${missing[@]}"
}

step_system_update() {
    sudo apt-get update -qq
    sudo NEEDRESTART_MODE=a DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
}

step_configure_ufw() {
    if sudo ufw status | grep -q "Status: active"; then
        return 0
    fi
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    echo "y" | sudo ufw enable
}

step_harden_ssh() {
    local sshd_config="/etc/ssh/sshd_config"
    if grep -q "^PasswordAuthentication no" "$sshd_config" 2>/dev/null; then
        return 0
    fi
    sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$sshd_config"
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
}

step_install_tailscale() {
    # Check if tailscale is installed AND authenticated
    if command -v tailscale &>/dev/null; then
        if sudo tailscale status &>/dev/null 2>&1; then
            # Already authenticated, just ensure UFW allows it
            if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
                sudo ufw allow in on tailscale0 2>/dev/null || true
            fi
            return 0
        fi
    fi

    # Install tailscale if not present
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
    fi

    # Authenticate using authkey if provided, otherwise skip
    if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
        sudo tailscale up --ssh --authkey="${TAILSCALE_AUTHKEY}"
    else
        # Mark that we need manual tailscale auth
        NEEDS_TAILSCALE_AUTH=true
        return 0  # Don't fail, just skip authentication
    fi

    # Configure firewall
    if command -v ufw &>/dev/null && sudo ufw status | grep -q "Status: active"; then
        sudo ufw allow in on tailscale0
    fi
}

step_unattended_upgrades() {
    if dpkg -s unattended-upgrades &>/dev/null 2>&1; then return 0; fi
    sudo NEEDRESTART_MODE=a apt-get install -y -qq unattended-upgrades
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' | \
        sudo tee /etc/apt/apt.conf.d/51isolab-unattended > /dev/null
}

step_install_docker() {
    if command -v docker &>/dev/null; then
        if ! docker info &>/dev/null 2>&1; then
            echo "Docker is installed but not accessible. Adding user to docker group..."
            sudo usermod -aG docker "$USER"
            NEEDS_RELOGIN=true
        else
            echo "Docker is already installed and accessible"
        fi
        return 0
    fi

    echo "Installing Docker from get.docker.com..."
    if ! curl -fsSL https://get.docker.com | sh; then
        echo ""
        echo "ERROR: Docker installation failed"
        echo "Check your internet connection and try again"
        return 1
    fi

    echo "Adding user to docker group..."
    sudo usermod -aG docker "$USER"
    NEEDS_RELOGIN=true
    echo "Docker installed successfully"
}

step_install_gvisor() {
    if command -v runsc &>/dev/null && docker info 2>/dev/null | grep -q runsc; then
        echo "gVisor (runsc) is already installed and configured"
        return 0
    fi

    echo "Adding gVisor repository..."
    if ! curl -fsSL https://gvisor.dev/archive.key | \
        sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg; then
        echo "ERROR: Failed to download gVisor GPG key"
        return 1
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | \
        sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null

    echo "Installing runsc..."
    sudo apt-get update -qq
    if ! sudo NEEDRESTART_MODE=a apt-get install -y -qq runsc; then
        echo "ERROR: Failed to install runsc"
        return 1
    fi

    echo "Configuring Docker to use gVisor runtime..."
    sudo runsc install
    sudo systemctl restart docker
    echo "gVisor installed and configured successfully"
}

step_build_image() {
    # Check if image already exists
    if docker image inspect isolab:latest &>/dev/null 2>&1; then
        echo "Image already exists, skipping build"
        return 0
    fi

    # Check Docker access - try with sg if needed
    if ! docker info &>/dev/null 2>&1; then
        # If Docker was just installed, use sg to access docker group
        # (usermod added us to the group but current shell doesn't see it yet)
        if [ "$NEEDS_RELOGIN" = true ]; then
            echo "Using sg to access Docker (group membership not yet active in this shell)"
            sg docker -c "docker build -t isolab:latest '${SCRIPT_DIR}/image'"
            return $?
        else
            echo ""
            echo "ERROR: Cannot access Docker daemon"
            echo ""
            echo "This usually means you need to:"
            echo "  1. Log out and back in (for docker group to take effect)"
            echo "  2. Then re-run: ./setup.sh"
            echo ""
            return 1
        fi
    fi

    # Build with progress output
    docker build -t isolab:latest "${SCRIPT_DIR}/image"
}

step_setup_networks() {
    # Check Docker access - try with sg if needed
    if ! docker info &>/dev/null 2>&1; then
        # If Docker was just installed, use sg to access docker group
        # (usermod added us to the group but current shell doesn't see it yet)
        if [ "$NEEDS_RELOGIN" = true ]; then
            echo "Using sg to access Docker (group membership not yet active in this shell)"
            sg docker -c "bash '${SCRIPT_DIR}/scripts/setup-networks.sh'"
            return $?
        else
            echo ""
            echo "ERROR: Cannot access Docker daemon"
            echo ""
            echo "This usually means you need to:"
            echo "  1. Log out and back in (for docker group to take effect)"
            echo "  2. Then re-run: ./setup.sh"
            echo ""
            return 1
        fi
    fi

    # Run network setup script
    bash "${SCRIPT_DIR}/scripts/setup-networks.sh"
}

step_install_cli() {
    local target="/usr/local/bin/isolab"
    chmod +x "${SCRIPT_DIR}/isolab.sh"
    if [ -L "$target" ] && [ "$(readlink "$target")" = "${SCRIPT_DIR}/isolab.sh" ]; then
        return 0
    fi
    sudo ln -sf "${SCRIPT_DIR}/isolab.sh" "$target"
}

step_install_dashboard() {
    pip install flask docker --break-system-packages 2>/dev/null || pip install flask docker
}

# ── Installation Screen ────────────────────────────────

screen_install() {
    clear_screen

    echo ""
    echo -e "  ${AMBER}${BOLD}Installing${NC}"
    echo -e "  ${DIM_AMBER}This may take a few minutes...${NC}"
    echo ""

    # Clear log
    : > /tmp/isolab-setup.log

    local step_num=0
    local total_steps=0
    local errors=0

    # Count total steps
    total_steps=3  # packages + docker + gvisor (always)
    if [ "$SETUP_MODE" = "full" ]; then
        total_steps=$((total_steps + 1))  # hardening packages
    fi
    for i in $(seq 0 $((${#OPTION_KEYS[@]} - 1))); do
        if [ "${SELECTED_OPTIONS[$i]}" -eq 1 ]; then
            total_steps=$((total_steps + 1))
        fi
    done

    progress_label() {
        step_num=$((step_num + 1))
        echo -e "${DIM}[${step_num}/${total_steps}]${NC} $1"
    }

    # Pre-flight (not counted as a step, but required)
    do_preflight

    # -- Full mode: system update
    if is_selected "system_update"; then
        run_step "$(progress_label "System update")" step_system_update || errors=$((errors + 1))
    fi

    # -- Full mode: hardening packages
    if [ "$SETUP_MODE" = "full" ]; then
        run_step "$(progress_label "Hardening packages")" step_hardening_packages || errors=$((errors + 1))
    fi

    # -- Full mode: UFW
    if is_selected "ufw"; then
        run_step "$(progress_label "UFW firewall")" step_configure_ufw || errors=$((errors + 1))
    fi

    # -- Full mode: SSH hardening
    if is_selected "ssh_harden"; then
        run_step "$(progress_label "SSH hardening")" step_harden_ssh || errors=$((errors + 1))
    fi

    # -- Full mode: Tailscale
    if is_selected "tailscale"; then
        run_step "$(progress_label "Tailscale")" step_install_tailscale || errors=$((errors + 1))
    fi

    # -- Full mode: unattended upgrades
    if is_selected "unattended"; then
        run_step "$(progress_label "Automatic security updates")" step_unattended_upgrades || errors=$((errors + 1))
    fi

    # -- Always: system packages
    run_step "$(progress_label "System packages")" step_system_packages || errors=$((errors + 1))

    # -- Always: Docker
    run_step "$(progress_label "Docker")" step_install_docker || errors=$((errors + 1))

    # -- Always: gVisor
    run_step "$(progress_label "gVisor")" step_install_gvisor || errors=$((errors + 1))

    # -- Optional: build image (verbose mode - shows docker build output)
    if is_selected "build_image"; then
        step_num=$((step_num + 1))
        echo ""
        echo -e "  ${DIM}[${step_num}/${total_steps}]${NC} ${AMBER}${BOLD}Build Isolab image${NC}"
        echo -e "  ${DIM}Building container image with dev tools (Python, Node.js, etc).${NC}"
        echo -e "  ${DIM}This takes 3-5 minutes and will show build progress...${NC}"
        echo ""
        if step_build_image 2>&1 | tee -a /tmp/isolab-setup.log; then
            echo ""
            echo -e "  ${GREEN}✓${NC} Build Isolab image"
        else
            echo ""
            echo -e "  ${RED}✗${NC} Build Isolab image"
            errors=$((errors + 1))
        fi
    fi

    # -- Optional: setup network (verbose mode - shows iptables output)
    if is_selected "setup_network"; then
        step_num=$((step_num + 1))
        echo ""
        echo -e "  ${DIM}[${step_num}/${total_steps}]${NC} ${AMBER}${BOLD}Restricted network${NC}"
        echo -e "  ${DIM}Creating Docker network with iptables rules for package-only access${NC}"
        echo ""
        if step_setup_networks 2>&1 | tee -a /tmp/isolab-setup.log; then
            echo ""
            echo -e "  ${GREEN}✓${NC} Restricted network"
        else
            echo ""
            echo -e "  ${RED}✗${NC} Restricted network"
            errors=$((errors + 1))
        fi
    fi

    # -- Optional: CLI
    if is_selected "install_cli"; then
        run_step "$(progress_label "Install CLI")" step_install_cli || errors=$((errors + 1))
    fi

    # -- Optional: dashboard
    if is_selected "dashboard"; then
        run_step "$(progress_label "Web dashboard")" step_install_dashboard || errors=$((errors + 1))
    fi

    echo ""
    if [ "$errors" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}All steps completed successfully${NC}"
    else
        echo -e "  ${RED}${BOLD}${errors} step(s) had errors${NC}"
        echo -e "  ${DIM}Check /tmp/isolab-setup.log for details${NC}"
    fi

    wait_for_enter
}

# ── Summary Screen ──────────────────────────────────────

screen_summary() {
    clear_screen

    echo ""
    print_logo true
    echo ""

    local w=52

    draw_box "$w" "Setup Complete"
    draw_box_empty "$w"

    # Show what was installed
    draw_box_line "$w" "${WHITE}Installed:${NC}"
    draw_box_line "$w" "  ${GREEN}✓${NC} System packages"
    draw_box_line "$w" "  ${GREEN}✓${NC} Docker"
    draw_box_line "$w" "  ${GREEN}✓${NC} gVisor"

    for i in $(seq 0 $((${#OPTION_KEYS[@]} - 1))); do
        if [ "${SELECTED_OPTIONS[$i]}" -eq 1 ]; then
            draw_box_line "$w" "  ${GREEN}✓${NC} ${OPTION_LABELS[$i]}"
        fi
    done

    draw_box_separator "$w"
    draw_box_line "$w" "${WHITE}Quick start:${NC}"
    draw_box_empty "$w"
    draw_box_line "$w" "  ${AMBER}isolab create myproject${NC}"
    draw_box_line "$w" "  ${AMBER}isolab ssh myproject${NC}"
    draw_box_line "$w" "  ${AMBER}isolab rm myproject${NC}"
    draw_box_empty "$w"

    if [ "$NEEDS_RELOGIN" = true ]; then
        draw_box_separator "$w"
        draw_box_line "$w" "${RED}⚠  Action required:${NC}"
        draw_box_line "$w" "  Log out and back in for Docker"
        draw_box_line "$w" "  group access to take effect."
        draw_box_empty "$w"
    fi

    if [ "$NEEDS_TAILSCALE_AUTH" = true ]; then
        draw_box_separator "$w"
        draw_box_line "$w" "${AMBER}⚠  Tailscale authentication needed:${NC}"
        draw_box_line "$w" "  ${WHITE}sudo tailscale up --ssh${NC}"
        draw_box_line "$w" "  Then visit the URL shown to authenticate."
        draw_box_empty "$w"
    fi

    draw_box_line "$w" "${DIM}Logs: /tmp/isolab-setup.log${NC}"
    draw_box_empty "$w"
    draw_box_bottom "$w"

    echo ""
}

# ── Non-Interactive Fallback ────────────────────────────

run_auto_mode() {
    echo ""
    echo -e "  ${DIM_AMBER}⬡${NC} ${AMBER}${BOLD}ISOLAB SETUP${NC} ${DIM}(non-interactive)${NC}"
    echo -e "  ${DIM_AMBER}──────────────────────────────────────${NC}"
    echo ""

    # Pre-flight
    if [ "$(id -u)" -eq 0 ]; then
        echo -e "  ${RED}✗${NC} Do not run as root."
        exit 1
    fi
    if ! command -v sudo &>/dev/null; then
        echo -e "  ${RED}✗${NC} sudo is required."
        exit 1
    fi
    if ! sudo -n true 2>/dev/null; then
        echo -e "  ${AMBER}ℹ${NC}  sudo access required"
        sudo true || exit 1
    fi

    echo -e "  ${AMBER}Mode:${NC} Quick Setup (auto)"
    echo ""

    : > /tmp/isolab-setup.log

    local errors=0
    local step=0
    local total=6

    auto_step() {
        step=$((step + 1))
        local label="$1"
        shift
        echo -ne "  ${DIM}[${step}/${total}]${NC} ${label}..."
        if eval "$@" >> /tmp/isolab-setup.log 2>&1; then
            echo -e " ${GREEN}✓${NC}"
        else
            echo -e " ${RED}✗${NC}"
            errors=$((errors + 1))
        fi
    }

    auto_step "System packages" step_system_packages
    auto_step "Docker" step_install_docker
    auto_step "gVisor" step_install_gvisor
    auto_step "Build image" step_build_image
    auto_step "Restricted network" step_setup_networks
    auto_step "Install CLI" step_install_cli

    echo ""
    if [ "$errors" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}✓ Setup complete${NC}"
    else
        echo -e "  ${RED}${BOLD}${errors} step(s) failed${NC}"
        echo -e "  ${DIM}Check /tmp/isolab-setup.log${NC}"
    fi

    echo ""
    echo -e "  ${AMBER}Quick start:${NC}"
    echo -e "    isolab create myproject"
    echo -e "    isolab ssh myproject"
    echo ""

    if [ "$NEEDS_RELOGIN" = true ]; then
        echo -e "  ${RED}⚠${NC}  Log out and back in for Docker group access"
        echo ""
    fi
}

# ── Main ────────────────────────────────────────────────

usage() {
    echo -e "${AMBER}${BOLD}Isolab Setup${NC}"
    echo ""
    echo "Usage: ./setup.sh [options]"
    echo ""
    echo "Options:"
    echo "  (none)       Interactive wizard (when running in a terminal)"
    echo "  --auto       Non-interactive mode with quick-setup defaults"
    echo "  --help, -h   Show this message"
    echo ""
    echo "The interactive wizard lets you choose between Quick Setup"
    echo "(Docker + gVisor + Isolab) and Full Setup (system hardening"
    echo "+ Tailscale + Docker + gVisor + Isolab) with toggleable options."
    echo ""
    echo "When piped or without a TTY, falls back to --auto mode."
}

main() {
    local auto_mode=false

    case "${1:-}" in
        --auto)
            auto_mode=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        "")
            ;;
        *)
            echo -e "${RED}Unknown option:${NC} $1"
            usage
            exit 1
            ;;
    esac

    # Decide interactive vs non-interactive
    if [ "$auto_mode" = true ]; then
        run_auto_mode
        exit 0
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        # stdin or stdout is not a terminal
        run_auto_mode
        exit 0
    fi

    # ── Interactive mode ──
    INTERACTIVE=true
    TERM_SAVED=$(stty -g 2>/dev/null || true)

    screen_welcome
    screen_detect
    screen_mode
    screen_options
    screen_review
    screen_install
    screen_summary
}

main "$@"
