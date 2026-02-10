#!/bin/bash
set -e

# ── Inject SSH key ─────────────────────────────────────
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "$SSH_PUBLIC_KEY" > /home/sandbox/.ssh/authorized_keys
    chmod 600 /home/sandbox/.ssh/authorized_keys
    chown sandbox:sandbox /home/sandbox/.ssh/authorized_keys
fi

# ── Write metadata for MOTD and prompt ─────────────────
echo "${ISOLAB_NET_MODE:-ISOLATED}" > /home/sandbox/.isolab-net-mode
echo "${HOSTNAME:-isolab}" > /home/sandbox/.isolab-name
chown sandbox:sandbox /home/sandbox/.isolab-net-mode /home/sandbox/.isolab-name

# ── Start cron (disk watchdog) ─────────────────────────
cron

# ── Start SSH daemon ───────────────────────────────────
exec /usr/sbin/sshd -D -e
