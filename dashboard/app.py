#!/usr/bin/env python3
"""
Isolab Dashboard — Retro computing themed management UI
for disposable LLM development containers.
"""

import os
import sys
import subprocess
import hashlib
import secrets
import getpass
import time
from datetime import datetime

from flask import Flask, render_template_string, jsonify, request, session, redirect, url_for

import docker

app = Flask(__name__)
client = docker.from_env()

CONTAINER_PREFIX = "iso-"
ISOLAB_IMAGE = os.environ.get("ISOLAB_IMAGE", "isolab:latest")
SSH_KEY_FILE = os.environ.get(
    "SSH_KEY_FILE", os.path.expanduser("~/.ssh/id_ed25519.pub")
)
SSH_BASE_PORT = 2200
CONFIG_DIR = os.path.expanduser("~/.config/isolab")
MODES_DIR = os.path.join(CONFIG_DIR, "modes")
DASHBOARD_ENV = os.path.join(CONFIG_DIR, "dashboard.env")
ISOLAB_BIN = os.environ.get(
    "ISOLAB_BIN",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "isolab.sh"),
)

# Network mode definitions
NET_MODES = {
    "none": "ISOLATED",
    "packages": "PACKAGES",
    "web": "WEB",
    "open": "OPEN",
}


def _isolab_cmd(*args):
    """Run an isolab.sh subcommand. Returns (ok, output)."""
    try:
        result = subprocess.run(
            ["sudo", "-n", ISOLAB_BIN, *args],
            capture_output=True,
            text=True,
            timeout=15,
        )
        return result.returncode == 0, result.stdout + result.stderr
    except Exception as e:
        return False, str(e)


# ─── Auth ──────────────────────────────────────────────


def load_dashboard_config():
    """Load credentials from dashboard.env."""
    config = {}
    if not os.path.exists(DASHBOARD_ENV):
        return None
    with open(DASHBOARD_ENV) as f:
        for line in f:
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                config[key.strip()] = value.strip()
    required = [
        "ISOLAB_DASH_USER",
        "ISOLAB_DASH_HASH",
        "ISOLAB_DASH_SALT",
        "ISOLAB_DASH_SECRET",
    ]
    if all(k in config for k in required):
        return config
    return None


def hash_password(password, salt=None):
    """Hash password with scrypt. Returns (hash_hex, salt_hex)."""
    if salt is None:
        salt = secrets.token_bytes(32)
    elif isinstance(salt, str):
        salt = bytes.fromhex(salt)
    h = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1, dklen=64)
    return h.hex(), salt.hex()


def verify_password(password, stored_hash, salt_hex):
    """Verify password against stored hash."""
    computed, _ = hash_password(password, salt_hex)
    return secrets.compare_digest(computed, stored_hash)


def set_password_interactive():
    """Interactive password setup."""
    print("═" * 50)
    print("  ISOLAB DASHBOARD — SET PASSWORD")
    print("═" * 50)
    username = input("Username [admin]: ").strip() or "admin"
    password = getpass.getpass("Password: ")
    if not password:
        print("Error: password cannot be empty.")
        sys.exit(1)
    confirm = getpass.getpass("Confirm:  ")
    if password != confirm:
        print("Error: passwords do not match.")
        sys.exit(1)
    hash_hex, salt_hex = hash_password(password)
    secret_key = secrets.token_hex(32)
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(DASHBOARD_ENV, "w") as f:
        f.write(f"ISOLAB_DASH_USER={username}\n")
        f.write(f"ISOLAB_DASH_HASH={hash_hex}\n")
        f.write(f"ISOLAB_DASH_SALT={salt_hex}\n")
        f.write(f"ISOLAB_DASH_SECRET={secret_key}\n")
    os.chmod(DASHBOARD_ENV, 0o600)
    print(f"\n  Credentials saved to {DASHBOARD_ENV}")
    print(f"  Username: {username}")
    print("  Password: ****")
    print("\n  Restart the dashboard to apply.")


# ─── Rate Limiter ──────────────────────────────────────

_rate_limits = {}


def rate_limit_check(key, max_requests, window_seconds):
    """Returns (allowed, retry_after). Cleans expired entries."""
    now = time.time()
    if key not in _rate_limits:
        _rate_limits[key] = []
    _rate_limits[key] = [t for t in _rate_limits[key] if now - t < window_seconds]
    if len(_rate_limits[key]) >= max_requests:
        oldest = _rate_limits[key][0]
        retry_after = int(window_seconds - (now - oldest)) + 1
        return False, retry_after
    _rate_limits[key].append(now)
    return True, 0


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
        name = c.name.removeprefix(CONTAINER_PREFIX)
        labels = c.labels

        ssh_port = "N/A"
        if c.status == "running":
            ports = c.attrs.get("NetworkSettings", {}).get("Ports", {})
            if "22/tcp" in ports and ports["22/tcp"]:
                ssh_port = ports["22/tcp"][0].get("HostPort", "N/A")

        # Read mode from file first, fall back to Docker label
        mode_file = os.path.join(MODES_DIR, name)
        if os.path.exists(mode_file):
            with open(mode_file) as mf:
                net_mode = mf.read().strip()
        else:
            label = labels.get("isolab.net", "none")
            # Map old label formats
            label_map = {
                "--net=none": "none", "none": "none",
                "--net=packages": "web", "packages": "web",
                "--net=full": "open", "full": "open", "open": "open",
                "--net=web": "web", "web": "web",
            }
            net_mode = label_map.get(label, "none")
        net_display = NET_MODES.get(net_mode, net_mode.upper())

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


# ─── Auth Middleware ────────────────────────────────────


@app.before_request
def require_auth():
    if request.path in ("/login", "/favicon.ico"):
        return None
    if not session.get("authenticated"):
        if request.path.startswith("/api/"):
            return jsonify({"error": "Unauthorized"}), 401
        return redirect(url_for("login"))
    if request.method == "POST":
        token = request.headers.get("X-CSRF-Token", "")
        if not token or not secrets.compare_digest(
            token, session.get("csrf_token", "")
        ):
            return jsonify({"error": "Invalid CSRF token"}), 403
    if request.path == "/api/lab/create" and request.method == "POST":
        ip = request.remote_addr
        allowed, retry_after = rate_limit_check(f"create:{ip}", 10, 60)
        if not allowed:
            return (
                jsonify({"error": "Rate limit exceeded", "retry_after": retry_after}),
                429,
            )


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET":
        return render_template_string(LOGIN_HTML, error=None)
    ip = request.remote_addr
    allowed, retry_after = rate_limit_check(f"login:{ip}", 5, 60)
    if not allowed:
        return (
            render_template_string(
                LOGIN_HTML,
                error=f"Too many attempts. Try again in {retry_after}s.",
            ),
            429,
        )
    username = request.form.get("username", "")
    password = request.form.get("password", "")
    if username == app.config.get("DASH_USER") and verify_password(
        password, app.config.get("DASH_HASH", ""), app.config.get("DASH_SALT", "")
    ):
        session.clear()
        session["authenticated"] = True
        session["username"] = username
        session["csrf_token"] = secrets.token_hex(32)
        return redirect(url_for("index"))
    return render_template_string(LOGIN_HTML, error="Invalid credentials"), 401


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


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

    # Validate and normalize mode
    mode_map = {"none": "none", "packages": "packages", "web": "web", "open": "open", "full": "open"}
    mode = mode_map.get(net, "none")
    net_display = NET_MODES.get(mode, "ISOLATED")

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
                "isolab.net": mode,
                "isolab.created": datetime.now().isoformat(),
            },
        )
        # Persist mode and apply iptables rules
        os.makedirs(MODES_DIR, exist_ok=True)
        with open(os.path.join(MODES_DIR, name), "w") as mf:
            mf.write(mode)
        _isolab_cmd("set-net", name, mode)
        return jsonify({"ok": True, "name": name, "port": port})
    except Exception as e:
        app.logger.exception("Failed to create lab %s", name)
        return jsonify({"error": "Internal error creating lab"}), 500


@app.route("/api/lab/<name>/stop", methods=["POST"])
def api_stop(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        _isolab_cmd("set-net", name, "open")  # clear rules before stop
        c.stop(timeout=5)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/start", methods=["POST"])
def api_start(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        c.start()
        # Re-apply network rules from persisted mode
        mode_file = os.path.join(MODES_DIR, name)
        mode = "none"
        if os.path.exists(mode_file):
            with open(mode_file) as mf:
                mode = mf.read().strip()
        _isolab_cmd("set-net", name, mode)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/restart", methods=["POST"])
def api_restart(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        _isolab_cmd("set-net", name, "open")  # clear rules before restart
        c.restart(timeout=5)
        # Re-apply network rules from persisted mode
        mode_file = os.path.join(MODES_DIR, name)
        mode = "none"
        if os.path.exists(mode_file):
            with open(mode_file) as mf:
                mode = mf.read().strip()
        _isolab_cmd("set-net", name, mode)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/<name>/remove", methods=["POST"])
def api_remove(name):
    try:
        c = client.containers.get(f"{CONTAINER_PREFIX}{name}")
        _isolab_cmd("set-net", name, "open")  # clear rules
        c.remove(force=True)
        # Clean up mode file
        mode_file = os.path.join(MODES_DIR, name)
        if os.path.exists(mode_file):
            os.remove(mode_file)
        return jsonify({"ok": True})
    except docker.errors.NotFound:
        return jsonify({"error": "Not found"}), 404


@app.route("/api/lab/nuke", methods=["POST"])
def api_nuke():
    containers = client.containers.list(all=True, filters={"label": "isolab=true"})
    count = 0
    for c in containers:
        name = c.name.removeprefix(CONTAINER_PREFIX)
        _isolab_cmd("set-net", name, "open")  # clear rules
        c.remove(force=True)
        count += 1
    # Clean up all mode files
    if os.path.isdir(MODES_DIR):
        for f in os.listdir(MODES_DIR):
            os.remove(os.path.join(MODES_DIR, f))
    return jsonify({"ok": True, "removed": count})


# ─── UI ─────────────────────────────────────────────────


@app.route("/")
def index():
    return render_template_string(
        DASHBOARD_HTML, csrf_token=session.get("csrf_token", "")
    )


DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ISOLAB</title>
<meta name="csrf-token" content="{{ csrf_token }}">
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
    width: 200px;
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
  .badge-net-web { color: var(--cyan); border-color: var(--cyan-dim); background: rgba(0, 221, 255, 0.06); }
  .badge-net-open { color: var(--green); border-color: var(--green-dim); background: rgba(0, 255, 136, 0.06); }

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
      <h1><svg width="24" height="24" viewBox="0 0 256 256" fill="var(--green)" style="vertical-align:middle;margin-right:8px;filter:drop-shadow(0 0 12px var(--green-glow))"><path d="M221.69,199.77,160,96.92V40h8a8,8,0,0,0,0-16H88a8,8,0,0,0,0,16h8V96.92L34.31,199.77A16,16,0,0,0,48,224H208a16,16,0,0,0,13.72-24.23ZM110.86,103.25A7.93,7.93,0,0,0,112,99.14V40h32V99.14a7.93,7.93,0,0,0,1.14,4.11L183.36,167c-12,2.37-29.07,1.37-51.75-10.11-15.91-8.05-31.05-12.32-45.22-12.81ZM48,208l28.54-47.58c14.25-1.74,30.31,1.85,47.82,10.72,19,9.61,35,12.88,48,12.88a69.89,69.89,0,0,0,19.55-2.7L208,208Z"/></svg>Isolab</h1>
      <div class="header-meta">
        <div>HOST: <span id="hostname">—</span></div>
        <div>UPTIME: <span id="clock">—</span></div>
        <div style="margin-top:4px"><a href="/logout" style="color:var(--text-dim);text-decoration:none;font-size:10px;letter-spacing:1px">LOGOUT ▸</a></div>
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
      <option value="packages">PACKAGES (dns filtered)</option>
      <option value="web">WEB (http/https)</option>
      <option value="open">OPEN (unrestricted)</option>
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
const CSRF_TOKEN = document.querySelector('meta[name="csrf-token"]').content;
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
      'WEB': 'badge-net-web',
      'OPEN': 'badge-net-open',
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
    const res = await fetch(`${API}/api/lab/${name}/${action}`, { method: 'POST', headers: {'X-CSRF-Token': CSRF_TOKEN} });
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
      headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': CSRF_TOKEN },
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
    const res = await fetch(`${API}/api/lab/nuke`, { method: 'POST', headers: {'X-CSRF-Token': CSRF_TOKEN} });
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


LOGIN_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ISOLAB — Login</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600;700&family=Space+Mono:wght@400;700&display=swap');

  :root {
    --bg: #0a0e14;
    --bg-panel: #0d1117;
    --border: #1e2a3a;
    --green: #00ff88;
    --green-dim: #00cc6a;
    --green-glow: rgba(0, 255, 136, 0.15);
    --red: #ff4444;
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
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
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

  .login-box {
    background: var(--bg-panel);
    border: 1px solid var(--border);
    padding: 32px;
    width: 340px;
    position: relative;
  }

  .login-box::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 2px;
    background: linear-gradient(90deg, var(--green), transparent);
    opacity: 0.6;
  }

  .login-box h1 {
    font-family: 'Space Mono', monospace;
    font-size: 20px;
    font-weight: 700;
    color: var(--green);
    letter-spacing: 4px;
    text-transform: uppercase;
    text-shadow: 0 0 20px var(--green-glow);
    text-align: center;
    margin-bottom: 24px;
  }

  .login-box svg {
    display: block;
    margin: 0 auto 16px;
    filter: drop-shadow(0 0 12px var(--green-glow));
  }

  label {
    display: block;
    font-size: 10px;
    color: var(--text-dim);
    text-transform: uppercase;
    letter-spacing: 2px;
    margin-bottom: 6px;
    margin-top: 14px;
  }

  label:first-of-type { margin-top: 0; }

  .input {
    font-family: 'IBM Plex Mono', monospace;
    font-size: 12px;
    padding: 8px 12px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text-bright);
    outline: none;
    width: 100%;
  }

  .input:focus {
    border-color: var(--green-dim);
    box-shadow: 0 0 8px var(--green-glow);
  }

  .error-msg {
    color: var(--red);
    font-size: 11px;
    margin-top: 12px;
    text-align: center;
  }

  .btn {
    font-family: 'IBM Plex Mono', monospace;
    font-size: 12px;
    font-weight: 600;
    padding: 10px 16px;
    border: 1px solid var(--green-dim);
    background: var(--bg-panel);
    color: var(--green);
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 1px;
    width: 100%;
    margin-top: 20px;
    transition: all 0.15s ease;
  }

  .btn:hover {
    background: rgba(0, 255, 136, 0.12);
    box-shadow: 0 0 12px var(--green-glow);
  }
</style>
</head>
<body>
<div class="login-box">
  <svg width="32" height="32" viewBox="0 0 256 256" fill="var(--green)"><path d="M221.69,199.77,160,96.92V40h8a8,8,0,0,0,0-16H88a8,8,0,0,0,0,16h8V96.92L34.31,199.77A16,16,0,0,0,48,224H208a16,16,0,0,0,13.72-24.23ZM110.86,103.25A7.93,7.93,0,0,0,112,99.14V40h32V99.14a7.93,7.93,0,0,0,1.14,4.11L183.36,167c-12,2.37-29.07,1.37-51.75-10.11-15.91-8.05-31.05-12.32-45.22-12.81ZM48,208l28.54-47.58c14.25-1.74,30.31,1.85,47.82,10.72,19,9.61,35,12.88,48,12.88a69.89,69.89,0,0,0,19.55-2.7L208,208Z"/></svg>
  <h1>Isolab</h1>
  <form method="POST" action="/login">
    <label>Username</label>
    <input class="input" type="text" name="username" placeholder="admin" autofocus>
    <label>Password</label>
    <input class="input" type="password" name="password">
    {% if error %}<div class="error-msg">{{ error }}</div>{% endif %}
    <button class="btn" type="submit">Login ▸</button>
  </form>
</div>
</body>
</html>"""


if __name__ == "__main__":
    if "--set-password" in sys.argv:
        set_password_interactive()
        sys.exit(0)

    config = load_dashboard_config()
    if not config:
        print("═" * 50)
        print("  ISOLAB DASHBOARD — NOT CONFIGURED")
        print()
        print("  Run first:  python3 dashboard/app.py --set-password")
        print("═" * 50)
        sys.exit(1)

    app.secret_key = config["ISOLAB_DASH_SECRET"]
    app.config["DASH_USER"] = config["ISOLAB_DASH_USER"]
    app.config["DASH_HASH"] = config["ISOLAB_DASH_HASH"]
    app.config["DASH_SALT"] = config["ISOLAB_DASH_SALT"]
    app.config["SESSION_COOKIE_HTTPONLY"] = True
    app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

    bind = os.environ.get("ISOLAB_BIND", "127.0.0.1")
    port = int(os.environ.get("ISOLAB_PORT", "8080"))
    print("═" * 50)
    print("  ISOLAB DASHBOARD")
    print(f"  http://{bind}:{port}")
    print("═" * 50)
    app.run(host=bind, port=port, debug=False)
