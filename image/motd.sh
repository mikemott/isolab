#!/bin/bash
# ── Isolab login banner ────────────────────────────────

NET_MODE=$(cat /home/sandbox/.isolab-net-mode 2>/dev/null || echo "UNKNOWN")
LAB_NAME=$(cat /home/sandbox/.isolab-name 2>/dev/null || echo "isolab")

GREEN='\033[0;32m'
RED='\033[0;31m'
AMBER='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

case "$NET_MODE" in
    ISOLATED)
        NET_COLOR="$RED"
        NET_ICON="◉ LOCKED"
        NET_DESC="No network access. Fully sandboxed."
        ;;
    PACKAGES)
        NET_COLOR="$AMBER"
        NET_ICON="◎ RESTRICTED"
        NET_DESC="Outbound to package registries only (ports 80/443)."
        ;;
    FULL)
        NET_COLOR="$CYAN"
        NET_ICON="○ OPEN"
        NET_DESC="Full network access. Be cautious."
        ;;
    *)
        NET_COLOR="$DIM"
        NET_ICON="? UNKNOWN"
        NET_DESC=""
        ;;
esac

MEM_TOTAL=$(free -h 2>/dev/null | awk '/Mem:/{print $2}' || echo "?")
MEM_USED=$(free -h 2>/dev/null | awk '/Mem:/{print $3}' || echo "?")
DISK_USED=$(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}' || echo "?")

echo ""
echo -e "${GREEN}${BOLD}  ⬡ ISOLAB: ${LAB_NAME}${NC}"
echo -e "${DIM}  ──────────────────────────────────────${NC}"
echo -e "  ${DIM}Network :${NC} ${NET_COLOR}${BOLD}${NET_ICON}${NC}"
echo -e "  ${DIM}          ${NET_DESC}${NC}"
echo -e "  ${DIM}Memory  :${NC} ${MEM_USED} / ${MEM_TOTAL}"
echo -e "  ${DIM}Disk    :${NC} ${DISK_USED}"
echo -e "  ${DIM}Logs    :${NC} ~/logs/"
echo -e "  ${DIM}Work    :${NC} ~/workspace/"
echo -e "${DIM}  ──────────────────────────────────────${NC}"
echo -e "  ${DIM}tmux: auto-attached. Ctrl-b d to detach.${NC}"
echo -e "  ${DIM}netcheck: test network connectivity.${NC}"
echo ""
