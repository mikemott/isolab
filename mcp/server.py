#!/usr/bin/env python3
"""
Isolab MCP Server

Provides MCP tools for managing isolab sandboxes from Claude Code and other MCP clients.
"""

import json
import os
import subprocess
from typing import Any

import docker
from mcp.server import Server
from mcp.types import Tool, TextContent

CONTAINER_PREFIX = "iso-"
ISOLAB_IMAGE = os.environ.get("ISOLAB_IMAGE", "isolab:latest")
SSH_KEY_FILE = os.environ.get("SSH_KEY_FILE", os.path.expanduser("~/.ssh/id_ed25519.pub"))
SSH_BASE_PORT = 2200

app = Server("isolab")
docker_client = docker.from_env()


def get_bind_ip() -> str:
    """Get Tailscale IP for binding, fall back to localhost."""
    try:
        result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            ts_ip = result.stdout.strip().split("\n")[0]
            if ts_ip:
                return ts_ip
    except Exception:
        pass
    return "127.0.0.1"


def get_ssh_port(name: str) -> str:
    """Get SSH port for a container."""
    try:
        container = docker_client.containers.get(f"{CONTAINER_PREFIX}{name}")
        ports = container.attrs.get("NetworkSettings", {}).get("Ports", {})
        if "22/tcp" in ports and ports["22/tcp"]:
            return ports["22/tcp"][0].get("HostPort", "N/A")
    except docker.errors.NotFound:
        pass
    return "N/A"


def find_available_port() -> int:
    """Find next available SSH port."""
    port = SSH_BASE_PORT
    used_ports = set()

    for container in docker_client.containers.list(all=True, filters={"label": "isolab=true"}):
        ports = container.attrs.get("NetworkSettings", {}).get("Ports", {})
        if "22/tcp" in ports and ports["22/tcp"]:
            used_ports.add(int(ports["22/tcp"][0].get("HostPort", 0)))

    while port in used_ports:
        port += 1

    return port


@app.list_tools()
async def list_tools() -> list[Tool]:
    """List available isolab management tools."""
    return [
        Tool(
            name="isolab_create",
            description="Create a new isolated sandbox container",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name for the sandbox (alphanumeric, hyphens, underscores)",
                    },
                    "network": {
                        "type": "string",
                        "enum": ["none", "packages", "full"],
                        "description": "Network mode: none (isolated), packages (pypi/npm only), full (unrestricted)",
                        "default": "none",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="isolab_list",
            description="List all sandbox containers with their status",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        Tool(
            name="isolab_start",
            description="Start a stopped sandbox",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox to start",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="isolab_stop",
            description="Stop a running sandbox (preserves tmux sessions)",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox to stop",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="isolab_remove",
            description="Permanently destroy a sandbox",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox to remove",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="isolab_status",
            description="Get detailed status of a specific sandbox",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="isolab_exec",
            description="Execute a command in a sandbox and return the output",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox",
                    },
                    "command": {
                        "type": "string",
                        "description": "Command to execute",
                    },
                },
                "required": ["name", "command"],
            },
        ),
        Tool(
            name="isolab_logs",
            description="Get session logs from a sandbox",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Name of the sandbox",
                    },
                    "lines": {
                        "type": "integer",
                        "description": "Number of lines to tail (default: 50)",
                        "default": 50,
                    },
                },
                "required": ["name"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: Any) -> list[TextContent]:
    """Handle tool calls."""

    try:
        if name == "isolab_create":
            return await create_sandbox(arguments)
        elif name == "isolab_list":
            return await list_sandboxes(arguments)
        elif name == "isolab_start":
            return await start_sandbox(arguments)
        elif name == "isolab_stop":
            return await stop_sandbox(arguments)
        elif name == "isolab_remove":
            return await remove_sandbox(arguments)
        elif name == "isolab_status":
            return await get_status(arguments)
        elif name == "isolab_exec":
            return await exec_command(arguments)
        elif name == "isolab_logs":
            return await get_logs(arguments)
        else:
            return [TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as e:
        return [TextContent(type="text", text=f"Error: {str(e)}")]


async def create_sandbox(args: dict) -> list[TextContent]:
    """Create a new sandbox."""
    name = args["name"]
    network = args.get("network", "none")
    container_name = f"{CONTAINER_PREFIX}{name}"

    # Check if already exists
    try:
        docker_client.containers.get(container_name)
        return [TextContent(type="text", text=f"Error: Lab '{name}' already exists")]
    except docker.errors.NotFound:
        pass

    # Read SSH key
    try:
        with open(SSH_KEY_FILE) as f:
            ssh_key = f.read().strip()
    except FileNotFoundError:
        return [TextContent(type="text", text=f"Error: SSH key not found at {SSH_KEY_FILE}")]

    # Configure network
    net_map = {
        "none": {"network_mode": "none", "label": "--net=none", "display": "ISOLATED"},
        "packages": {"network": "isolab-packages", "label": "--net=packages", "display": "PACKAGES"},
        "full": {"label": "--net=full", "display": "FULL"},
    }

    net_config = net_map.get(network, net_map["none"])
    net_kwargs = {k: v for k, v in net_config.items() if k not in ["label", "display"]}

    # Find available port
    port = find_available_port()
    bind_ip = get_bind_ip()

    # Create container
    from datetime import datetime

    container = docker_client.containers.run(
        ISOLAB_IMAGE,
        detach=True,
        name=container_name,
        runtime="runsc",
        hostname=name,
        mem_limit="4g",
        nano_cpus=2_000_000_000,
        ports={"22/tcp": (bind_ip, port)},
        environment={
            "SSH_PUBLIC_KEY": ssh_key,
            "ISOLAB_NET_MODE": net_config["display"],
        },
        labels={
            "isolab": "true",
            "isolab.name": name,
            "isolab.net": net_config["label"],
            "isolab.created": datetime.now().isoformat(),
        },
        **net_kwargs,
    )

    ssh_host = bind_ip if bind_ip != "127.0.0.1" else "localhost"
    result = f"""Created sandbox '{name}'
Network: {net_config['display']}
SSH Port: {port}
Container ID: {container.id[:12]}

Connect with:
  ssh -p {port} sandbox@{ssh_host}

Or use isolab CLI:
  isolab ssh {name}"""

    return [TextContent(type="text", text=result)]


async def list_sandboxes(args: dict) -> list[TextContent]:
    """List all sandboxes."""
    containers = docker_client.containers.list(all=True, filters={"label": "isolab=true"})

    if not containers:
        return [TextContent(type="text", text="No sandboxes found.")]

    lines = ["Sandboxes:", ""]
    lines.append(f"{'NAME':<16} {'STATUS':<10} {'PORT':<8} {'NETWORK':<12} {'CREATED':<20}")
    lines.append("-" * 70)

    for container in containers:
        name = container.name.replace(CONTAINER_PREFIX, "")
        status = container.status
        ssh_port = get_ssh_port(name)
        net = container.labels.get("isolab.net", "?").replace("--net=", "")
        created = container.labels.get("isolab.created", "unknown")

        if created != "unknown":
            from datetime import datetime
            try:
                created_dt = datetime.fromisoformat(created)
                created = created_dt.strftime("%Y-%m-%d %H:%M")
            except ValueError:
                pass

        lines.append(f"{name:<16} {status:<10} {ssh_port:<8} {net:<12} {created:<20}")

    return [TextContent(type="text", text="\n".join(lines))]


async def start_sandbox(args: dict) -> list[TextContent]:
    """Start a stopped sandbox."""
    name = args["name"]
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)
        container.start()
        port = get_ssh_port(name)
        return [TextContent(type="text", text=f"Started sandbox '{name}' on port {port}")]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def stop_sandbox(args: dict) -> list[TextContent]:
    """Stop a running sandbox."""
    name = args["name"]
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)
        container.stop(timeout=5)
        return [TextContent(type="text", text=f"Stopped sandbox '{name}'. Tmux sessions preserved.")]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def remove_sandbox(args: dict) -> list[TextContent]:
    """Remove a sandbox permanently."""
    name = args["name"]
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)
        container.remove(force=True)
        return [TextContent(type="text", text=f"Destroyed sandbox '{name}'.")]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def get_status(args: dict) -> list[TextContent]:
    """Get detailed status of a sandbox."""
    name = args["name"]
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)
        container.reload()

        status = container.status
        ssh_port = get_ssh_port(name)
        net = container.labels.get("isolab.net", "unknown")
        created = container.labels.get("isolab.created", "unknown")

        # Get resource usage if running
        cpu_pct = "N/A"
        mem_usage = "N/A"

        if status == "running":
            try:
                stats = container.stats(stream=False)
                cpu_delta = (
                    stats["cpu_stats"]["cpu_usage"]["total_usage"]
                    - stats["precpu_stats"]["cpu_usage"]["total_usage"]
                )
                sys_delta = (
                    stats["cpu_stats"]["system_cpu_usage"]
                    - stats["precpu_stats"]["system_cpu_usage"]
                )
                num_cpus = stats["cpu_stats"].get("online_cpus", 1)
                if sys_delta > 0:
                    cpu_pct = f"{(cpu_delta / sys_delta) * num_cpus * 100:.1f}%"

                mem_bytes = stats["memory_stats"].get("usage", 0)
                mem_usage = f"{mem_bytes / (1024**2):.0f}MB"
            except Exception:
                pass

        result = f"""Sandbox: {name}
Status: {status}
Network: {net}
SSH Port: {ssh_port}
CPU: {cpu_pct}
Memory: {mem_usage}
Created: {created}
Container ID: {container.id[:12]}"""

        return [TextContent(type="text", text=result)]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def exec_command(args: dict) -> list[TextContent]:
    """Execute a command in a sandbox."""
    name = args["name"]
    command = args["command"]
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)

        if container.status != "running":
            return [TextContent(type="text", text=f"Error: Sandbox '{name}' is not running")]

        result = container.exec_run(
            ["bash", "-c", command],
            user="sandbox",
            workdir="/home/sandbox",
        )

        output = result.output.decode("utf-8", errors="replace")
        exit_code = result.exit_code

        response = f"Command: {command}\nExit Code: {exit_code}\n\nOutput:\n{output}"
        return [TextContent(type="text", text=response)]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def get_logs(args: dict) -> list[TextContent]:
    """Get session logs from a sandbox."""
    name = args["name"]
    lines = args.get("lines", 50)
    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        container = docker_client.containers.get(container_name)

        # List log files
        result = container.exec_run(
            ["bash", "-c", "ls -t ~/logs/ 2>/dev/null | head -1"],
            user="sandbox",
        )

        if result.exit_code != 0:
            return [TextContent(type="text", text=f"No logs found for sandbox '{name}'")]

        latest_log = result.output.decode("utf-8").strip()

        if not latest_log:
            return [TextContent(type="text", text=f"No logs found for sandbox '{name}'")]

        # Tail the latest log
        result = container.exec_run(
            ["bash", "-c", f"tail -n {lines} ~/logs/{latest_log}"],
            user="sandbox",
        )

        output = result.output.decode("utf-8", errors="replace")
        response = f"Latest log: {latest_log}\n\n{output}"

        return [TextContent(type="text", text=response)]
    except docker.errors.NotFound:
        return [TextContent(type="text", text=f"Error: Sandbox '{name}' not found")]


async def main():
    """Run the MCP server."""
    from mcp.server.stdio import stdio_server

    async with stdio_server() as (read_stream, write_stream):
        await app.run(
            read_stream,
            write_stream,
            app.create_initialization_options(),
        )


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
