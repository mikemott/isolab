#!/usr/bin/env python3
"""
Isolab Dashboard — Retro computing themed management UI
for disposable LLM development containers.
"""

import os
import subprocess
from datetime import datetime

from flask import Flask, render_template_string, jsonify, request

import docker

app = Flask(__name__)
client = docker.from_env()

CONTAINER_PREFIX = "iso-"
ISOLAB_IMAGE = os.environ.get("ISOLAB_IMAGE", "isolab:latest")
SSH_KEY_FILE = os.environ.get(
    "SSH_KEY_FILE", os.path.expanduser("~/.ssh/id_ed25519.pub")
)
SSH_BASE_PORT = 2200


def get_bind_ip():
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


def get_sandboxes():
    sandboxes = []
    containers = client.containers.list(all=True, filters={"label": "isolab=true"})

    for c in containers:
        name = c.name.replace(CONTAINER_PREFIX, "")
        labels = c.labels

        ssh_port = "N/A"
        if c.status == "running":
            ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
            if "22/tcp" in ports and ports["22/tcp"]:
                ssh_port = ports["22/tcp"][0].get("HostPort", "N/A")

        net_mode = labels.get("isolab.net", "unknown")
        net_display = {
            "--net=none": "ISOLATED",
            "--net=packages": "PACKAGES",
            "--net=full": "FULL",
        }.get(net_mode, net_mode)

        created = labels.get("isolab.created", "")
        try:
            created_dt = datetime.fromisoformat(created)
            created_display = created_dt.strftime("%Y-%m-%d %H:%M")
        except (ValueError, TypeError):
            created_display = "unknown"

        cpu_pct = "—"
        mem_usage = "—"
        if c.status == "running":
            try:
                stats = c.stats(stream=False)
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

        sandboxes.append(
            {
                "name": name,
                "container_name": c.name,
                "status": c.status,
                "ssh_port": ssh_port,
                "network": net_display,
                "created": created_display,
                "cpu": cpu_pct,
                "memory": mem_usage,
            }
        )

    return sorted(sandboxes, key=lambda s: s["name"])


def get_host_stats():
    try:
        import shutil

        disk = shutil.disk_usage("/")
        disk_total = f"{disk.total / (1024**3):.0f}GB"
        disk_used = f"{disk.used / (1024**3):.1f}GB"
        disk_pct = f"{(disk.used / disk.total) * 100:.0f}%"
    except Exception:
        disk_total = disk_used = disk_pct = "?"

    try:
        with open("/proc/meminfo") as f:
            meminfo = {}
            for line in f:
                parts = line.split()
                if parts[0] in ("MemTotal:", "MemAvailable:"):
                    meminfo[parts[0]] = int(parts[1])
            mem_total = meminfo.get("MemTotal:", 0) / (1024 * 1024)
            mem_avail = meminfo.get("MemAvailable:", 0) / (1024 * 1024)
            mem_used = mem_total - mem_avail
    except Exception:
        mem_total = mem_used = 0

    try:
        with open("/proc/loadavg") as f:
            load = f.read().split()[:3]
            load_str = " / ".join(load)
    except Exception:
        load_str = "?"

    return {
        "disk_total": disk_total,
        "disk_used": disk_used,
        "disk_pct": disk_pct,
        "mem_total_gb": f"{mem_total:.1f}",
        "mem_used_gb": f"{mem_used:.1f}",
        "mem_pct": f"{(mem_used / mem_total * 100):.0f}%" if mem_total > 0 else "?",
        "load": load_str,
        "hostname": os.uname().nodename,
    }


# ─── API ────────────────────────────────────────────────


@app.route("/api/labs")
def api_labs():
    return jsonify(get_sandboxes())


@app.route("/api/host")
def api_host():
    return jsonify(get_host_stats())


@app.route("/api/lab/create", methods=["POST"])
def api_create():
    data = request.json
    name = data.get("name", "").strip()
    net = data.get("network", "none")

    if not name or not name.replace("-", "").replace("_", "").isalnum():
        return (
            jsonify({"error": "Invalid name. Use alphanumeric, hyphens, underscores."}),
            400,
        )

    container_name = f"{CONTAINER_PREFIX}{name}"

    try:
        client.containers.get(container_name)
        return jsonify({"error": f"Lab '{name}' already exists"}), 409
    except docker.errors.NotFound:
        pass

    try:
        with open(SSH_KEY_FILE) as f:
            ssh_key = f.read().strip()
    except FileNotFoundError:
        return jsonify({"error": f"SSH key not found: {SSH_KEY_FILE}"}), 500

    port = SSH_BASE_PORT
    used_ports = set()
    for c in client.containers.list(all=True, filters={"label": "isolab=true"}):
        ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
        if "22/tcp" in ports and ports["22/tcp"]:
            used_ports.add(int(ports["22/tcp"][0].get("HostPort", 0)))
    while port in used_ports:
        port += 1

    net_map = {
        "none": {"network_mode": "none"},
        "packages": {"network": "isolab-packages"},
        "full": {},
    }
    net_kwargs = net_map.get(net, {"network_mode": "none"})
    net_label = f"--net={net}"
    net_display = {"none": "ISOLATED", "packages": "PACKAGES", "full": "FULL"}.get(
        net, "ISOLATED"
    )

    bind_ip = get_bind_ip()

    try:
        client.containers.run(
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
                "ISOLAB_NET_MODE": net_display,
            },
            labels={
                "isolab": "true",
                "isolab.name": name,
                "isolab.net": net_label,
                "isolab.created": datetime.now().isoformat(),
            },
            **net_kwargs,
        )
        return jsonify({"ok": True, "name": name, "port": port})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/lab/<name>/stop", methods=["POST"])
def api_stop(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        c.stop(timeout=5)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/start", methods=["POST"])
def api_start(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        c.start()
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/restart", methods=["POST"])
def api_restart(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        c.restart(timeout=5)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/remove", methods=["POST"])
def api_remove(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        c.remove(force=True)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/nuke", methods=["POST"])
def api_nuke():
    containers = client.containers.list(all=True, filters={"label": "isolab=true"})
    count = 0
    for c in containers:
        c.remove(force=True)
        count += 1
    return jsonify({"ok": True, "removed": count})


# ─── UI ─────────────────────────────────────────────────


@app.route("/")
def index():
    return render_template_string(DASHBOARD_HTML)


DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ISOLAB</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&family=Space+Mono:wght@400;700&display=swap');

  :root {
    --bg: #0a0e14;
    --bg-panel: #0d1117;
    --bg-row: #111820;
    --bg-row-hover: #151d28;
    --border: #1e2a3a;
    --border-bright: #2d4158;
    --green: #00ff88;
    --green-dim: #00cc6a;
    --green-glow: rgba(0, 255, 136, 0.15);
    --amber: #ffaa00;
    --amber-dim: #cc8800;
    --red: #ff4444;
    --red-dim: #cc2222;
    --cyan: #00ddff;
    --cyan-dim: #00aacc;
    --text: #c0c8d4;
    --text-dim: #5a6a7a;
    --text-bright: #e8eef4;
  }

  * { margin: 0; padding: 0; box-sizing: border-box; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'IBM Plex Mono', 'Courier New', monospace;
    font-size: 13px;
    line-height: 1.5;
    min-height: 100vh;
  }

  body::after {
    content: '';
    position: fixed;
    top: 0; left: 0; right: 0; bottom: 0;
    background: repeating-linear-gradient(
      0deg, transparent, transparent 2px,
      rgba(0, 0, 0, 0.08) 2px, rgba(0, 0, 0, 0.08) 4px
    );
    pointer-events: none;
    z-index: 9999;
  }

  .container { max-width: 1200px; margin: 0 auto; padding: 24px; }

  .header {
    border: 1px solid var(--border);
    background: var(--bg-panel);
    padding: 20px 24px;
    margin-bottom: 20px;
    position: relative;
    overflow: hidden;
  }

  .header::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, var(--green), var(--cyan), var(--green));
    opacity: 0.6;
  }

  .header-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
  }

  .header h1 {
    font-family: 'Space Mono', monospace;
    font-size: 20px;
    font-weight: 700;
    color: var(--green);
    letter-spacing: 4px;
    text-transform: uppercase;
    text-shadow: 0 0 20px var(--green-glow);
  }

  .header-meta {
    font-size: 11px;
    color: var(--text-dim);
    text-align: right;
    line-height: 1.7;
  }

  .header-meta span { color: var(--cyan); }

  .stats-bar {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 12px;
    margin-bottom: 20px;
  }

  .stat-card {
    background: var(--bg-panel);
    border: 1px solid var(--border);
    padding: 14px 16px;
    position: relative;
  }

  .stat-card::before {
    content: '';
    position: absolute;
    top: 0; left: 0;
    width: 3px; height: 100%;
    background: var(--green-dim);
    opacity: 0.5;
  }

  .stat-label {
    font-size: 10px;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 4px;
  }

  .stat-value {
    font-family: 'Space Mono', monospace;
    font-size: 18px;
    font-weight: 700;
    color: var(--text-bright);
  }

  .stat-sub { font-size: 10px; color: var(--text-dim); margin-top: 2px; }

  .actions-bar {
    display: flex;
    gap: 10px;
    margin-bottom: 20px;
    align-items: center;
  }

  .btn {
    font-family: 'IBM Plex Mono', monospace;
    font-size: 12px;
    font-weight: 600;
    padding: 8px 16px;
    border: 1px solid var(--border);
    background: var(--bg-panel);
    color: var(--text);
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.15s ease;
    white-space: nowrap;
  }

  .btn:hover {
    border-color: var(--green-dim);
    color: var(--green);
    background: rgba(0, 255, 136, 0.05);
  }

  .btn-green { border-color: var(--green-dim); color: var(--green); }
  .btn-green:hover {
    background: rgba(0, 255, 136, 0.12);
    box-shadow: 0 0 12px var(--green-glow);
  }

  .btn-red { border-color: var(--red-dim); color: var(--red); }
  .btn-red:hover { background: rgba(255, 68, 68, 0.1); border-color: var(--red); }

  .btn-amber { border-color: var(--amber-dim); color: var(--amber); }
  .btn-amber:hover { background: rgba(255, 170, 0, 0.1); border-color: var(--amber); }

  .btn-sm { padding: 4px 10px; font-size: 11px; }

  .input {
    font-family: 'IBM Plex Mono', monospace;
    font-size: 12px;
    padding: 8px 12px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-bright);
    outline: none;
    width: 180px;
  }

  .input:focus {
    border-color: var(--green-dim);
    box-shadow: 0 0 8px var(--green-glow);
  }

  .input::placeholder { color: var(--text-dim); }

  select.input {
    appearance: none;
    cursor: pointer;
    width: 140px;
    padding-right: 24px;
    background-image: url("data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' width='12' height='6'%3E%3Cpath d='M0 0l6 6 6-6' fill='%235a6a7a'/%3E%3C/svg%3E");
    background-repeat: no-repeat;
    background-position: right 8px center;
  }

  .table-wrap {
    background: var(--bg-panel);
    border: 1px solid var(--border);
    overflow: hidden;
  }

  table { width: 100%; border-collapse: collapse; }

  thead th {
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--text-dim);
    padding: 12px 16px;
    text-align: left;
    border-bottom: 1px solid var(--border);
    background: var(--bg);
    position: sticky;
    top: 0;
  }

  tbody td {
    padding: 10px 16px;
    border-bottom: 1px solid var(--border);
    vertical-align: middle;
  }

  tbody tr { background: var(--bg-row); transition: background 0.1s; }
  tbody tr:hover { background: var(--bg-row-hover); }

  .name-cell { font-weight: 600; color: var(--text-bright); font-size: 13px; }
  .name-cell .prompt { color: var(--green-dim); margin-right: 4px; opacity: 0.7; }

  .badge {
    display: inline-block;
    padding: 2px 8px;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 1px;
    border: 1px solid;
  }

  .badge-running {
    color: var(--green);
    border-color: var(--green-dim);
    background: rgba(0, 255, 136, 0.08);
  }

  .badge-running::before {
    content: '●';
    margin-right: 4px;
    animation: pulse 2s infinite;
  }

  @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }

  .badge-stopped {
    color: var(--text-dim);
    border-color: var(--border);
    background: rgba(90, 106, 122, 0.08);
  }

  .badge-net-isolated { color: var(--red); border-color: var(--red-dim); background: rgba(255, 68, 68, 0.06); }
  .badge-net-packages { color: var(--amber); border-color: var(--amber-dim); background: rgba(255, 170, 0, 0.06); }
  .badge-net-full { color: var(--cyan); border-color: var(--cyan-dim); background: rgba(0, 221, 255, 0.06); }

  .ssh-cmd { font-size: 11px; color: var(--green-dim); cursor: pointer; opacity: 0.8; }
  .ssh-cmd:hover { opacity: 1; text-decoration: underline; }
  .mono-dim { color: var(--text-dim); font-size: 11px; }
  .actions-cell { display: flex; gap: 6px; flex-wrap: nowrap; }

  .empty-state { text-align: center; padding: 48px 24px; color: var(--text-dim); }
  .empty-state .ascii-art { font-size: 11px; color: var(--green-dim); opacity: 0.4; margin-bottom: 16px; line-height: 1.3; }

  .modal-backdrop {
    display: none;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.7);
    z-index: 1000;
    align-items: center;
    justify-content: center;
  }

  .modal-backdrop.active { display: flex; }

  .modal {
    background: var(--bg-panel);
    border: 1px solid var(--green-dim);
    padding: 24px;
    width: 380px;
    box-shadow: 0 0 40px var(--green-glow);
  }

  .modal h2 {
    font-family: 'Space Mono', monospace;
    font-size: 14px;
    color: var(--green);
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 20px;
  }

  .modal label {
    display: block;
    font-size: 10px;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 6px;
    margin-top: 14px;
  }

  .modal label:first-of-type { margin-top: 0; }
  .modal .input { width: 100%; }

  .modal-actions {
    display: flex;
    gap: 10px;
    margin-top: 20px;
    justify-content: flex-end;
  }

  .toast {
    position: fixed;
    bottom: 24px;
    right: 24px;
    padding: 10px 18px;
    font-family: 'IBM Plex Mono', monospace;
    font-size: 12px;
    border: 1px solid var(--green-dim);
    background: var(--bg-panel);
    color: var(--green);
    z-index: 2000;
    opacity: 0;
    transform: translateY(10px);
    transition: all 0.2s ease;
    pointer-events: none;
  }

  .toast.active { opacity: 1; transform: translateY(0); }
  .toast.error { border-color: var(--red-dim); color: var(--red); }

  .footer {
    text-align: center;
    padding: 20px;
    color: var(--text-dim);
    font-size: 10px;
    letter-spacing: 1px;
    text-transform: uppercase;
  }

  .footer a { color: var(--green-dim); text-decoration: none; }
  .footer a:hover { color: var(--green); }

  @media (max-width: 800px) {
    .stats-bar { grid-template-columns: repeat(2, 1fr); }
    .actions-bar { flex-wrap: wrap; }
    .container { padding: 12px; }
  }
</style>
</head>
<body>

<div class="container">

  <div class="header">
    <div class="header-row">
      <h1>⬡ Isolab</h1>
      <div class="header-meta">
        <div>HOST: <span id="hostname">—</span></div>
        <div>UPTIME: <span id="clock">—</span></div>
      </div>
    </div>
  </div>

  <div class="stats-bar">
    <div class="stat-card">
      <div class="stat-label">Labs</div>
      <div class="stat-value" id="stat-count">—</div>
      <div class="stat-sub" id="stat-running">— running</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Memory</div>
      <div class="stat-value" id="stat-mem">—</div>
      <div class="stat-sub" id="stat-mem-detail">—</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Disk</div>
      <div class="stat-value" id="stat-disk">—</div>
      <div class="stat-sub" id="stat-disk-detail">—</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Load</div>
      <div class="stat-value" id="stat-load">—</div>
      <div class="stat-sub">1 / 5 / 15 min</div>
    </div>
  </div>

  <div class="actions-bar">
    <button class="btn btn-green" onclick="showCreateModal()">+ New Lab</button>
    <button class="btn" onclick="refresh()">↻ Refresh</button>
    <div style="flex:1"></div>
    <button class="btn btn-red" onclick="nukeAll()">⚠ Nuke All</button>
  </div>

  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>Name</th>
          <th>Status</th>
          <th>Network</th>
          <th>SSH</th>
          <th>CPU</th>
          <th>Mem</th>
          <th>Created</th>
          <th>Actions</th>
        </tr>
      </thead>
      <tbody id="lab-tbody">
        <tr><td colspan="8"><div class="empty-state">Loading...</div></td></tr>
      </tbody>
    </table>
  </div>

  <div class="footer">
    Isolab &middot; gVisor + Docker &middot; <a href="https://gvisor.dev" target="_blank">gVisor docs</a>
  </div>

</div>

<div class="modal-backdrop" id="createModal">
  <div class="modal">
    <h2>▸ New Lab</h2>
    <label>Name</label>
    <input class="input" id="newName" placeholder="my-project" autofocus
           onkeydown="if(event.key==='Enter')doCreate()">
    <label>Network</label>
    <select class="input" id="newNet">
      <option value="none">ISOLATED (none)</option>
      <option value="packages">PACKAGES ONLY</option>
      <option value="full">FULL ACCESS</option>
    </select>
    <div class="modal-actions">
      <button class="btn" onclick="hideCreateModal()">Cancel</button>
      <button class="btn btn-green" onclick="doCreate()">Create</button>
    </div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const API = '';
let refreshTimer;

async function refresh() {
  try {
    const [lRes, hRes] = await Promise.all([
      fetch(API + '/api/labs'),
      fetch(API + '/api/host'),
    ]);
    const labs = await lRes.json();
    const host = await hRes.json();
    renderLabs(labs);
    renderHost(host, labs);
  } catch (e) {
    console.error('Refresh failed:', e);
  }
}

function renderHost(host, labs) {
  document.getElementById('hostname').textContent = host.hostname || '?';
  const running = labs.filter(s => s.status === 'running').length;
  document.getElementById('stat-count').textContent = labs.length;
  document.getElementById('stat-running').textContent = `${running} running`;
  document.getElementById('stat-mem').textContent = host.mem_pct;
  document.getElementById('stat-mem-detail').textContent = `${host.mem_used_gb} / ${host.mem_total_gb} GB`;
  document.getElementById('stat-disk').textContent = host.disk_pct;
  document.getElementById('stat-disk-detail').textContent = `${host.disk_used} / ${host.disk_total}`;
  document.getElementById('stat-load').textContent = host.load;
}

function renderLabs(labs) {
  const tbody = document.getElementById('lab-tbody');

  if (labs.length === 0) {
    tbody.innerHTML = `<tr><td colspan="8">
      <div class="empty-state">
        <div class="ascii-art"><pre>
    ┌──────────────────┐
    │  NO ACTIVE LABS  │
    │                  │
    │  Create one to   │
    │  get started.    │
    └──────────────────┘</pre></div>
        Hit "+ New Lab" to spin one up.
      </div>
    </td></tr>`;
    return;
  }

  tbody.innerHTML = labs.map(s => {
    const statusClass = s.status === 'running' ? 'badge-running' : 'badge-stopped';
    const netClass = {
      'ISOLATED': 'badge-net-isolated',
      'PACKAGES': 'badge-net-packages',
      'FULL': 'badge-net-full',
    }[s.network] || '';

    const sshDisplay = s.ssh_port !== 'N/A'
      ? `<span class="ssh-cmd" onclick="copySSH('${s.ssh_port}')" title="Click to copy">:${s.ssh_port}</span>`
      : '<span class="mono-dim">—</span>';

    const isRunning = s.status === 'running';

    return `<tr>
      <td class="name-cell"><span class="prompt">$</span>${esc(s.name)}</td>
      <td><span class="badge ${statusClass}">${s.status}</span></td>
      <td><span class="badge ${netClass}">${s.network}</span></td>
      <td>${sshDisplay}</td>
      <td class="mono-dim">${s.cpu}</td>
      <td class="mono-dim">${s.memory}</td>
      <td class="mono-dim">${s.created}</td>
      <td>
        <div class="actions-cell">
          ${isRunning
            ? `<button class="btn btn-sm btn-amber" onclick="doAction('stop','${esc(s.name)}')">Stop</button>
               <button class="btn btn-sm" onclick="doAction('restart','${esc(s.name)}')">Restart</button>`
            : `<button class="btn btn-sm btn-green" onclick="doAction('start','${esc(s.name)}')">Start</button>`
          }
          <button class="btn btn-sm btn-red" onclick="doAction('remove','${esc(s.name)}')">Delete</button>
        </div>
      </td>
    </tr>`;
  }).join('');
}

async function doAction(action, name) {
  if (action === 'remove' && !confirm(`Destroy lab "${name}"? This is permanent.`)) return;
  try {
    const res = await fetch(`${API}/api/lab/${name}/${action}`, { method: 'POST' });
    const data = await res.json();
    if (data.ok) toast(`${action}: ${name}`);
    else toast(data.error || 'Failed', true);
  } catch (e) { toast('Request failed', true); }
  setTimeout(refresh, 500);
}

async function doCreate() {
  const name = document.getElementById('newName').value.trim();
  const net = document.getElementById('newNet').value;
  if (!name) return;
  try {
    const res = await fetch(`${API}/api/lab/create`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, network: net }),
    });
    const data = await res.json();
    if (data.ok) { toast(`Created "${name}" on port ${data.port}`); hideCreateModal(); }
    else toast(data.error || 'Failed', true);
  } catch (e) { toast('Request failed', true); }
  setTimeout(refresh, 500);
}

async function nukeAll() {
  if (!confirm('Destroy ALL labs? This cannot be undone.')) return;
  try {
    const res = await fetch(`${API}/api/lab/nuke`, { method: 'POST' });
    const data = await res.json();
    toast(`Nuked ${data.removed} lab(s)`);
  } catch (e) { toast('Nuke failed', true); }
  setTimeout(refresh, 500);
}

function showCreateModal() {
  document.getElementById('newName').value = '';
  document.getElementById('createModal').classList.add('active');
  setTimeout(() => document.getElementById('newName').focus(), 100);
}

function hideCreateModal() { document.getElementById('createModal').classList.remove('active'); }

document.getElementById('createModal').addEventListener('click', e => {
  if (e.target === e.currentTarget) hideCreateModal();
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') hideCreateModal(); });

function copySSH(port) {
  const hostname = document.getElementById('hostname').textContent;
  const cmd = `ssh -p ${port} sandbox@${hostname}`;
  navigator.clipboard.writeText(cmd).then(() => toast(`Copied: ${cmd}`));
}

function toast(msg, isError = false) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = 'toast active' + (isError ? ' error' : '');
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.classList.remove('active'), 3000);
}

function esc(s) { const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }

function updateClock() {
  document.getElementById('clock').textContent = new Date().toLocaleTimeString('en-US', { hour12: false });
}

refresh();
updateClock();
setInterval(updateClock, 1000);
refreshTimer = setInterval(refresh, 10000);
</script>

</body>
</html>"""


if __name__ == "__main__":
    print("═" * 50)
    print("  ISOLAB DASHBOARD")
    print("  http://0.0.0.0:8080")
    print("═" * 50)
    app.run(host="0.0.0.0", port=8080, debug=False)
