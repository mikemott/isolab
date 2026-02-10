#!/bin/bash
# ── Isolab disk watchdog ───────────────────────────────
# Runs every 10 min via cron. Alerts via tmux if disk is filling up.

THRESHOLD=85
WARNING_FILE="$HOME/.disk-warning"

USAGE=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')

if [ "$USAGE" -ge "$THRESHOLD" ]; then
    echo "⚠ DISK ${USAGE}% FULL — consider cleaning up or destroying this lab" > "$WARNING_FILE"

    LAB_NAME=$(cat "$HOME/.isolab-name" 2>/dev/null || echo "isolab")
    if tmux has-session -t "$LAB_NAME" 2>/dev/null; then
        tmux display-message -t "$LAB_NAME" "⚠ WARNING: Disk at ${USAGE}% capacity"
    fi
else
    rm -f "$WARNING_FILE"
fi
