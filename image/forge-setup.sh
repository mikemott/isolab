#!/bin/bash
# Forge setup for Isolab VMs — runs at container start
# Configures MCP server, session hook, and CLAUDE.md for remote API mode
set -euo pipefail

FORGE_DIR="/opt/forge"
CLAUDE_DIR="/home/sandbox/.claude"

# Skip if credentials not provided
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "forge-setup: no ANTHROPIC_API_KEY — skipping"
    exit 0
fi

FORGE_API_URL="${FORGE_API_URL:-https://forge-mcp.mottvt.com}"

mkdir -p "${CLAUDE_DIR}"

# ── MCP config ────────────────────────────────────────
MCP_CONFIG="${CLAUDE_DIR}/mcp.json"

node -e "
const fs = require('fs');
const env = {
    FORGE_API_URL: process.env.FORGE_API_URL || 'https://forge-mcp.mottvt.com',
    ANTHROPIC_API_KEY: process.env.ANTHROPIC_API_KEY
};
if (process.env.CF_ACCESS_CLIENT_ID) env.CF_ACCESS_CLIENT_ID = process.env.CF_ACCESS_CLIENT_ID;
if (process.env.CF_ACCESS_CLIENT_SECRET) env.CF_ACCESS_CLIENT_SECRET = process.env.CF_ACCESS_CLIENT_SECRET;
if (process.env.ISOLAB_VM_ID) env.ISOLAB_VM_ID = process.env.ISOLAB_VM_ID;

let config = {};
try { config = JSON.parse(fs.readFileSync('${MCP_CONFIG}', 'utf8')); } catch {}
config.mcpServers = config.mcpServers || {};
config.mcpServers.forge = {
    command: 'node',
    args: ['${FORGE_DIR}/dist/mcp/server.js'],
    env
};
fs.writeFileSync('${MCP_CONFIG}', JSON.stringify(config, null, 2));
"

# ── Session hook ──────────────────────────────────────
SETTINGS="${CLAUDE_DIR}/settings.json"
HOOK_CMD="${FORGE_DIR}/hooks/on-session-end.sh"

if [ -f "${HOOK_CMD}" ]; then
    node -e "
const fs = require('fs');
let config = {};
try { config = JSON.parse(fs.readFileSync('${SETTINGS}', 'utf8')); } catch {}
config.hooks = config.hooks || {};
config.hooks.SessionEnd = config.hooks.SessionEnd || [];
const exists = config.hooks.SessionEnd.some(e =>
    e.hooks?.some(h => h.command?.includes('on-session-end.sh'))
);
if (!exists) {
    config.hooks.SessionEnd.push({
        hooks: [{ type: 'command', command: '${HOOK_CMD}' }]
    });
}
fs.writeFileSync('${SETTINGS}', JSON.stringify(config, null, 2));
"
fi

# ── Symlink CLAUDE.md ─────────────────────────────────
FORGE_CLAUDE_MD="${FORGE_DIR}/config/claude-global.md"
if [ -f "${FORGE_CLAUDE_MD}" ]; then
    ln -sf "${FORGE_CLAUDE_MD}" "${CLAUDE_DIR}/CLAUDE.md"
fi

chown -R sandbox:sandbox "${CLAUDE_DIR}"

echo "forge-setup: configured (remote API → ${FORGE_API_URL})"
