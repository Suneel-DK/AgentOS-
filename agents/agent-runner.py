#!/usr/bin/env python3
"""
AgentOS - Agent Runner
HTTP server on port 3001 that spawns, monitors, and kills AI agents.
Each agent is an isolated subprocess running a Python script.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

# ── Config ────────────────────────────────────────────
PORT = 3001
AGENTS_DIR = Path(__file__).parent
TEMPLATES_DIR = AGENTS_DIR / "templates"
MAX_AGENTS = 5
MAX_LOG_LINES = 500  # Max log lines kept per agent in memory

# ── Agent Registry ────────────────────────────────────
# agents[id] = {id, name, template, status, pid, start_time, end_time, logs, process}
agents: dict = {}
agents_lock = threading.Lock()


# ── Built-in template scripts ─────────────────────────
# Stored as strings so the runner works even if the templates/ dir is missing.
BUILTIN_TEMPLATES = {
    "monitor": {
        "name": "System Monitor",
        "desc": "Watches CPU/RAM every 30s and logs alerts if thresholds are exceeded",
        "script": '''\
#!/usr/bin/env python3
"""AgentOS Template — System Monitor"""
import time, psutil, sys

CPU_THRESHOLD = 80   # percent
RAM_THRESHOLD = 85   # percent
INTERVAL = 30        # seconds

print("[monitor] System monitor agent started", flush=True)
print(f"[monitor] Alerting if CPU > {CPU_THRESHOLD}% or RAM > {RAM_THRESHOLD}%", flush=True)

while True:
    cpu = psutil.cpu_percent(interval=1)
    ram = psutil.virtual_memory().percent
    print(f"[monitor] CPU: {cpu:.1f}%  RAM: {ram:.1f}%", flush=True)
    if cpu > CPU_THRESHOLD:
        print(f"[ALERT] CPU usage high: {cpu:.1f}%", flush=True)
    if ram > RAM_THRESHOLD:
        print(f"[ALERT] RAM usage high: {ram:.1f}%", flush=True)
    time.sleep(INTERVAL - 1)
''',
    },
    "chat": {
        "name": "Chat Agent",
        "desc": "Connects to Ollama and answers questions in a loop (reads stdin)",
        "script": '''\
#!/usr/bin/env python3
"""AgentOS Template — Chat Agent"""
import json, urllib.request, sys

OLLAMA_URL = "http://localhost:11434/api/generate"
MODEL = "llama3.2:3b"

print(f"[chat] Chat agent started — using model: {MODEL}", flush=True)
print("[chat] Send prompts via the API (POST /agents/<id>/input)", flush=True)

for line in sys.stdin:
    prompt = line.strip()
    if not prompt:
        continue
    print(f"[chat] Prompt received: {prompt}", flush=True)
    try:
        payload = json.dumps({"model": MODEL, "prompt": prompt, "stream": False}).encode()
        req = urllib.request.Request(OLLAMA_URL, data=payload,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
            print(f"[chat] Response: {data.get('response', '').strip()}", flush=True)
    except Exception as e:
        print(f"[chat] Error: {e}", flush=True)
''',
    },
    "hello": {
        "name": "Hello World",
        "desc": "Prints a greeting every 10 seconds — good for testing the agent runner",
        "script": '''\
#!/usr/bin/env python3
"""AgentOS Template — Hello World (test agent)"""
import time, sys

count = 0
print("[hello] Hello World agent started!", flush=True)
while True:
    count += 1
    print(f"[hello] Still alive — tick {count}", flush=True)
    time.sleep(10)
''',
    },
}


# ── Agent Lifecycle ───────────────────────────────────

def _stream_output(agent_id: str, stream, prefix: str):
    """Read lines from a subprocess stream and append to the agent's log buffer."""
    try:
        for raw_line in stream:
            line = raw_line.rstrip("\n")
            _append_log(agent_id, line)
    except Exception:
        pass


def _append_log(agent_id: str, line: str):
    """Thread-safe append to an agent's log."""
    with agents_lock:
        if agent_id not in agents:
            return
        log = agents[agent_id]["logs"]
        log.append({"ts": time.time(), "line": line})
        if len(log) > MAX_LOG_LINES:
            agents[agent_id]["logs"] = log[-MAX_LOG_LINES:]


def _watch_process(agent_id: str, process):
    """Wait for the process to exit and update agent status."""
    process.wait()
    with agents_lock:
        if agent_id in agents:
            status = "stopped" if process.returncode == 0 else "crashed"
            agents[agent_id]["status"] = status
            agents[agent_id]["end_time"] = time.time()
            agents[agent_id]["exit_code"] = process.returncode
    _append_log(agent_id, f"[runner] Agent exited with code {process.returncode}")


def start_agent(template_name: str, agent_name: str = "") -> dict:
    """Spawn a new agent subprocess from a built-in or file template."""
    with agents_lock:
        running = sum(1 for a in agents.values() if a["status"] == "running")
        if running >= MAX_AGENTS:
            return {"ok": False, "error": f"Max agents ({MAX_AGENTS}) already running"}

    # Resolve template
    if template_name in BUILTIN_TEMPLATES:
        script_src = BUILTIN_TEMPLATES[template_name]["script"]
        display_name = agent_name or BUILTIN_TEMPLATES[template_name]["name"]
    else:
        # Try loading from templates/ directory
        tmpl_path = TEMPLATES_DIR / f"{template_name}.py"
        if not tmpl_path.exists():
            return {"ok": False, "error": f"Template not found: {template_name}"}
        script_src = tmpl_path.read_text()
        display_name = agent_name or template_name

    agent_id = str(uuid.uuid4())[:8]

    # Write script to a temp file so we can run it as a subprocess
    script_path = AGENTS_DIR / f".agent_{agent_id}.py"
    script_path.write_text(script_src)

    try:
        process = subprocess.Popen(
            [sys.executable, str(script_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,  # Merge stderr into stdout
            stdin=subprocess.PIPE,
            text=True,
            bufsize=1,  # Line-buffered
        )
    except Exception as e:
        script_path.unlink(missing_ok=True)
        return {"ok": False, "error": str(e)}

    with agents_lock:
        agents[agent_id] = {
            "id": agent_id,
            "name": display_name,
            "template": template_name,
            "status": "running",
            "pid": process.pid,
            "start_time": time.time(),
            "end_time": None,
            "exit_code": None,
            "logs": [],
            "process": process,
            "script_path": str(script_path),
        }

    # Start threads to stream output and watch for exit
    threading.Thread(target=_stream_output, args=(agent_id, process.stdout, ""), daemon=True).start()
    threading.Thread(target=_watch_process, args=(agent_id, process), daemon=True).start()

    _append_log(agent_id, f"[runner] Agent started: {display_name} (pid {process.pid})")
    return {"ok": True, "id": agent_id, "name": display_name}


def kill_agent(agent_id: str) -> dict:
    """Send SIGTERM to an agent process, then SIGKILL after 3 seconds."""
    with agents_lock:
        agent = agents.get(agent_id)
        if not agent:
            return {"ok": False, "error": "Agent not found"}
        if agent["status"] != "running":
            return {"ok": False, "error": f"Agent is not running (status: {agent['status']})"}
        process = agent["process"]

    try:
        process.terminate()  # SIGTERM
        # Give it 3 seconds to die gracefully, then force kill
        threading.Timer(3, lambda: _force_kill(process)).start()
        _append_log(agent_id, "[runner] Kill signal sent — stopping agent...")
        return {"ok": True, "message": f"Agent {agent_id} stopping..."}
    except ProcessLookupError:
        return {"ok": True, "message": "Agent process already gone"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _force_kill(process):
    """Force-kill a process if it's still alive after graceful stop."""
    try:
        if process.poll() is None:
            process.kill()
    except Exception:
        pass


def send_input(agent_id: str, text: str) -> dict:
    """Write a line to the agent's stdin (for interactive agents like chat)."""
    with agents_lock:
        agent = agents.get(agent_id)
        if not agent or agent["status"] != "running":
            return {"ok": False, "error": "Agent not running"}
        process = agent["process"]
    try:
        process.stdin.write(text + "\n")
        process.stdin.flush()
        return {"ok": True}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def get_agent_info(agent: dict) -> dict:
    """Return a serializable snapshot of an agent (no process object)."""
    return {
        "id": agent["id"],
        "name": agent["name"],
        "template": agent["template"],
        "status": agent["status"],
        "pid": agent["pid"],
        "start_time": agent["start_time"],
        "end_time": agent["end_time"],
        "exit_code": agent["exit_code"],
        "log_lines": len(agent["logs"]),
    }


def cleanup_stopped():
    """Remove script temp files for stopped/crashed agents older than 10 minutes."""
    now = time.time()
    with agents_lock:
        for agent in list(agents.values()):
            if agent["status"] in ("stopped", "crashed"):
                end = agent.get("end_time") or 0
                if now - end > 600:
                    sp = Path(agent.get("script_path", ""))
                    if sp.exists():
                        sp.unlink(missing_ok=True)


# ── HTTP Handler ──────────────────────────────────────

class AgentHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        pass  # Suppress request logs

    def send_json(self, data, status=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path

        # GET /agents — list all agents
        if path == "/agents":
            with agents_lock:
                agent_list = [get_agent_info(a) for a in agents.values()]
            self.send_json({"agents": agent_list})

        # GET /agents/<id>/logs — get logs for one agent
        elif path.startswith("/agents/") and path.endswith("/logs"):
            agent_id = path[len("/agents/"):-len("/logs")]
            with agents_lock:
                agent = agents.get(agent_id)
            if not agent:
                self.send_json({"error": "Not found"}, 404)
            else:
                self.send_json({"id": agent_id, "logs": agent["logs"]})

        # GET /templates — list available templates
        elif path == "/templates":
            templates = [
                {"id": k, "name": v["name"], "desc": v["desc"]}
                for k, v in BUILTIN_TEMPLATES.items()
            ]
            # Also scan templates/ dir for custom scripts
            if TEMPLATES_DIR.exists():
                for f in TEMPLATES_DIR.glob("*.py"):
                    templates.append({
                        "id": f.stem,
                        "name": f.stem.replace("-", " ").title(),
                        "desc": "Custom template",
                    })
            self.send_json({"templates": templates})

        else:
            self.send_json({"error": "Not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {}

        # POST /agents — start a new agent
        if path == "/agents":
            template = payload.get("template", "").strip()
            name = payload.get("name", "").strip()
            if not template:
                self.send_json({"ok": False, "error": "template required"}, 400)
            else:
                self.send_json(start_agent(template, name))

        # POST /agents/<id>/input — send text to agent's stdin
        elif path.startswith("/agents/") and path.endswith("/input"):
            agent_id = path[len("/agents/"):-len("/input")]
            text = payload.get("text", "").strip()
            if not text:
                self.send_json({"ok": False, "error": "text required"}, 400)
            else:
                self.send_json(send_input(agent_id, text))

        else:
            self.send_json({"error": "Not found"}, 404)

    def do_DELETE(self):
        path = urlparse(self.path).path
        # DELETE /agents/<id>
        if path.startswith("/agents/"):
            agent_id = path[len("/agents/"):]
            if agent_id:
                self.send_json(kill_agent(agent_id))
            else:
                self.send_json({"ok": False, "error": "agent id required"}, 400)
        else:
            self.send_json({"error": "Not found"}, 404)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


# ── Cleanup thread ────────────────────────────────────

def _cleanup_loop():
    while True:
        time.sleep(300)
        cleanup_stopped()


# ── Main ──────────────────────────────────────────────

def main():
    TEMPLATES_DIR.mkdir(exist_ok=True)
    threading.Thread(target=_cleanup_loop, daemon=True).start()

    print(f"AgentOS Agent Runner starting on port {PORT}...")
    print(f"  API:       http://localhost:{PORT}/agents")
    print(f"  Templates: http://localhost:{PORT}/templates")
    print(f"  Max agents: {MAX_AGENTS}")

    server = HTTPServer(("0.0.0.0", PORT), AgentHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nAgent runner stopped.")
        # Kill all running agents on shutdown
        with agents_lock:
            for agent in agents.values():
                if agent["status"] == "running":
                    try:
                        agent["process"].terminate()
                    except Exception:
                        pass
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
