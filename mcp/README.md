# Isolab MCP Server

MCP server for managing isolab sandboxes from Claude Code and other MCP clients.

## Features

- **isolab_create** — Create new isolated sandbox containers
- **isolab_list** — List all sandboxes with status
- **isolab_start** / **isolab_stop** — Manage sandbox lifecycle
- **isolab_remove** — Permanently destroy sandboxes
- **isolab_status** — Get detailed sandbox information
- **isolab_exec** — Execute commands in sandboxes
- **isolab_logs** — View session logs

## Installation

### 1. Install dependencies

```bash
cd mcp
pip install -r requirements.txt
```

Or use uv (recommended):

```bash
uv pip install -r requirements.txt
```

### 2. Configure Claude Code

Add the isolab MCP server to your Claude Code settings:

**macOS/Linux**: `~/.claude/settings.json`

```json
{
  "mcpServers": {
    "isolab": {
      "command": "python3",
      "args": ["/path/to/isolab/mcp/server.py"],
      "env": {
        "ISOLAB_IMAGE": "isolab:latest",
        "SSH_KEY_FILE": "~/.ssh/id_ed25519.pub"
      }
    }
  }
}
```

**Important**: Replace `/path/to/isolab` with the actual path to your isolab installation.

### 3. Restart Claude Code

The MCP server will be automatically loaded when Claude Code starts.

## Usage

Once configured, you can use natural language in Claude Code:

```
Create a sandbox called 'test' with package network access

List all my sandboxes

Execute 'python --version' in the test sandbox

Get the logs from my test sandbox

Stop the test sandbox

Destroy the test sandbox
```

Claude Code will automatically use the appropriate isolab MCP tools.

## Environment Variables

- **ISOLAB_IMAGE** — Docker image to use (default: `isolab:latest`)
- **SSH_KEY_FILE** — Path to SSH public key (default: `~/.ssh/id_ed25519.pub`)

## Network Modes

- **none** (default) — No network access, fully isolated
- **packages** — Access to package registries only (pypi, npm, github)
- **full** — Unrestricted network access

## Tools Reference

### isolab_create

Create a new sandbox container.

**Parameters:**
- `name` (required) — Sandbox name (alphanumeric, hyphens, underscores)
- `network` (optional) — Network mode: `none`, `packages`, or `full` (default: `none`)

**Example:**
```
Create a sandbox called 'myproject' with full network access
```

### isolab_list

List all sandbox containers with their status.

**Example:**
```
Show me all my sandboxes
```

### isolab_start

Start a stopped sandbox.

**Parameters:**
- `name` (required) — Sandbox name

**Example:**
```
Start the myproject sandbox
```

### isolab_stop

Stop a running sandbox (preserves tmux sessions).

**Parameters:**
- `name` (required) — Sandbox name

**Example:**
```
Stop the myproject sandbox
```

### isolab_remove

Permanently destroy a sandbox.

**Parameters:**
- `name` (required) — Sandbox name

**Example:**
```
Delete the myproject sandbox
```

### isolab_status

Get detailed status and resource usage for a sandbox.

**Parameters:**
- `name` (required) — Sandbox name

**Example:**
```
Show me the status of myproject
```

### isolab_exec

Execute a command in a sandbox and return the output.

**Parameters:**
- `name` (required) — Sandbox name
- `command` (required) — Command to execute

**Example:**
```
Run 'df -h' in the myproject sandbox
```

### isolab_logs

Get session logs from a sandbox.

**Parameters:**
- `name` (required) — Sandbox name
- `lines` (optional) — Number of lines to tail (default: 50)

**Example:**
```
Show me the last 100 lines of logs from myproject
```

## Security Notes

- The MCP server uses the same security model as the isolab CLI
- All containers run under gVisor (runsc) for syscall-level isolation
- Default network mode is `none` (fully isolated)
- The server requires Docker daemon access (same permissions as isolab CLI)

## Troubleshooting

### Server not connecting

Check Claude Code logs for connection errors:

```bash
tail -f ~/.claude/logs/mcp-isolab.log
```

### Docker permission errors

Ensure your user has Docker access:

```bash
docker ps
```

If you get a permission error, add your user to the docker group:

```bash
sudo usermod -aG docker $USER
```

Then log out and back in.

### SSH key not found

Set the SSH_KEY_FILE environment variable in your Claude Code settings:

```json
{
  "mcpServers": {
    "isolab": {
      "env": {
        "SSH_KEY_FILE": "/path/to/your/key.pub"
      }
    }
  }
}
```

## Development

### Running the server standalone

```bash
python3 server.py
```

The server communicates via stdin/stdout using the MCP protocol.

### Testing with MCP inspector

```bash
npx @modelcontextprotocol/inspector python3 server.py
```

This opens a web UI for testing MCP tools.

## License

MIT
