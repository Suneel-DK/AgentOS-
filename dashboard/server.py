#!/usr/bin/env python3
"""
AgentOS - Dashboard Server
Serves the dashboard UI and provides real system stats via a JSON API.
Runs on port 3000.
"""

import json
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse, parse_qs

import psutil

# ── Config ────────────────────────────────────────────
PORT = 3000
DASHBOARD_DIR = Path(__file__).parent
OLLAMA_SERVICE = "ollama"

# ── GPU Detection ─────────────────────────────────────
# Try to import pynvml for NVIDIA stats. Fails gracefully on CPU-only machines.
try:
    import pynvml
    pynvml.nvmlInit()
    GPU_AVAILABLE = True
    GPU_HANDLE = pynvml.nvmlDeviceGetHandleByIndex(0)
except Exception:
    GPU_AVAILABLE = False
    GPU_HANDLE = None


# ── Stat Collectors ───────────────────────────────────

def get_gpu_stats() -> dict:
    """Return GPU utilization, VRAM, and temperature. Returns None values if no GPU."""
    if not GPU_AVAILABLE:
        return {
            "gpu_name": "CPU Only",
            "gpu_percent": None,
            "gpu_vram_used_gb": None,
            "gpu_vram_total_gb": None,
            "gpu_temp_c": None,
        }
    try:
        name = pynvml.nvmlDeviceGetName(GPU_HANDLE)
        # pynvml may return bytes on older versions
        if isinstance(name, bytes):
            name = name.decode("utf-8")
        util = pynvml.nvmlDeviceGetUtilizationRates(GPU_HANDLE)
        mem = pynvml.nvmlDeviceGetMemoryInfo(GPU_HANDLE)
        temp = pynvml.nvmlDeviceGetTemperature(GPU_HANDLE, pynvml.NVML_TEMPERATURE_GPU)
        return {
            "gpu_name": name,
            "gpu_percent": util.gpu,
            "gpu_vram_used_gb": round(mem.used / (1024 ** 3), 1),
            "gpu_vram_total_gb": round(mem.total / (1024 ** 3), 1),
            "gpu_temp_c": temp,
        }
    except Exception as e:
        return {
            "gpu_name": "GPU Error",
            "gpu_percent": None,
            "gpu_vram_used_gb": None,
            "gpu_vram_total_gb": None,
            "gpu_temp_c": None,
        }


def get_system_stats() -> dict:
    """Return a full stats snapshot: CPU, RAM, GPU, uptime, agent count."""
    # CPU — sample over 0.5s for a reasonable reading
    cpu_percent = psutil.cpu_percent(interval=0.5)

    # RAM
    ram = psutil.virtual_memory()
    ram_used_gb = round(ram.used / (1024 ** 3), 1)
    ram_total_gb = round(ram.total / (1024 ** 3), 1)
    ram_percent = ram.percent

    # Uptime
    boot_time = psutil.boot_time()
    uptime_hours = round((time.time() - boot_time) / 3600, 1)

    # Count running processes with "ollama" or "python" agent names as a proxy
    # In a real deployment this would query the agent runner
    agent_count = count_agents()

    stats = {
        "cpu_percent": cpu_percent,
        "ram_used_gb": ram_used_gb,
        "ram_total_gb": ram_total_gb,
        "ram_percent": ram_percent,
        "uptime_hours": uptime_hours,
        "agent_count": agent_count,
    }
    stats.update(get_gpu_stats())
    return stats


def count_agents() -> int:
    """Count running agent processes (placeholder — replace when agent runner is built)."""
    count = 0
    for proc in psutil.process_iter(["name", "cmdline"]):
        try:
            cmdline = " ".join(proc.info.get("cmdline") or [])
            if "agentos-agent" in cmdline:
                count += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    return count


def get_models() -> list:
    """Return list of installed Ollama models by running `ollama list`."""
    try:
        result = subprocess.run(
            ["ollama", "list"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            return []

        models = []
        lines = result.stdout.strip().splitlines()
        # Skip the header line ("NAME  ID  SIZE  MODIFIED")
        for line in lines[1:]:
            parts = line.split()
            if not parts:
                continue
            models.append({
                "name": parts[0],
                "size": parts[2] if len(parts) > 2 else "?",
                "modified": " ".join(parts[3:]) if len(parts) > 3 else "?",
            })
        return models
    except FileNotFoundError:
        # Ollama is not installed yet
        return []
    except subprocess.TimeoutExpired:
        return []


def pull_model(model_name: str) -> dict:
    """Trigger `ollama pull <model>` in the background. Returns immediately."""
    if not model_name or len(model_name) > 200:
        return {"ok": False, "error": "Invalid model name"}
    import re
    if not re.match(r'^[a-zA-Z0-9:.\-_/]+$', model_name):
        return {"ok": False, "error": "Invalid characters in model name"}
    try:
        subprocess.Popen(
            ["ollama", "pull", model_name],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return {"ok": True, "message": f"Pulling {model_name} in background..."}
    except FileNotFoundError:
        return {"ok": False, "error": "Ollama is not installed"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def delete_model(model_name: str) -> dict:
    """Delete an installed Ollama model via `ollama rm <name>`."""
    if not model_name or len(model_name) > 200:
        return {"ok": False, "error": "Invalid model name"}
    import re
    if not re.match(r'^[a-zA-Z0-9:.\-_/]+$', model_name):
        return {"ok": False, "error": "Invalid characters in model name"}
    try:
        result = subprocess.run(
            ["ollama", "rm", model_name],
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode == 0:
            return {"ok": True, "message": f"Deleted {model_name}"}
        else:
            return {"ok": False, "error": result.stderr.strip() or "Delete failed"}
    except FileNotFoundError:
        return {"ok": False, "error": "Ollama is not installed"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Delete timed out"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def get_available_models() -> list:
    """Return a curated list of popular Ollama models with descriptions."""
    return [
        {"name": "llama3.2:3b",        "desc": "Meta Llama 3.2 — fast, 3B params, great for CPU",       "size": "~2 GB",  "tags": ["fast", "cpu-friendly"]},
        {"name": "llama3.2:1b",        "desc": "Meta Llama 3.2 — ultra-light, 1B params",                "size": "~1.3 GB","tags": ["fast", "cpu-friendly"]},
        {"name": "llama3.1:8b",        "desc": "Meta Llama 3.1 — 8B, strong general performance",        "size": "~4.7 GB","tags": ["general"]},
        {"name": "mistral:7b",         "desc": "Mistral 7B — excellent instruction following",            "size": "~4.1 GB","tags": ["general", "instruct"]},
        {"name": "mistral-nemo",       "desc": "Mistral NeMo — 12B, best open model at its size",        "size": "~7.1 GB","tags": ["general"]},
        {"name": "gemma2:2b",          "desc": "Google Gemma 2 — 2B, efficient and capable",             "size": "~1.6 GB","tags": ["fast", "cpu-friendly"]},
        {"name": "gemma2:9b",          "desc": "Google Gemma 2 — 9B, strong reasoning",                  "size": "~5.5 GB","tags": ["general"]},
        {"name": "phi3:mini",          "desc": "Microsoft Phi-3 Mini — tiny but surprisingly capable",   "size": "~2.2 GB","tags": ["fast", "cpu-friendly"]},
        {"name": "phi3:medium",        "desc": "Microsoft Phi-3 Medium — 14B, great quality",            "size": "~8.9 GB","tags": ["general"]},
        {"name": "qwen2.5:7b",         "desc": "Alibaba Qwen 2.5 — 7B, strong at code + multilingual",  "size": "~4.4 GB","tags": ["code", "multilingual"]},
        {"name": "qwen2.5-coder:7b",   "desc": "Qwen 2.5 Coder — specialist coding model",              "size": "~4.4 GB","tags": ["code"]},
        {"name": "deepseek-coder:6.7b","desc": "DeepSeek Coder — strong open-source code model",        "size": "~3.8 GB","tags": ["code"]},
        {"name": "deepseek-r1:7b",     "desc": "DeepSeek R1 — reasoning model with chain of thought",   "size": "~4.7 GB","tags": ["reasoning"]},
        {"name": "codellama:7b",       "desc": "Meta Code Llama — code generation and completion",       "size": "~3.8 GB","tags": ["code"]},
        {"name": "nomic-embed-text",   "desc": "Nomic Embed — text embeddings for RAG pipelines",       "size": "~274 MB","tags": ["embeddings", "rag"]},
        {"name": "mxbai-embed-large",  "desc": "MixedBread Embed — high-quality text embeddings",       "size": "~670 MB","tags": ["embeddings", "rag"]},
        {"name": "llava:7b",           "desc": "LLaVA — vision + language, describe images",            "size": "~4.5 GB","tags": ["vision", "multimodal"]},
    ]


def restart_ollama() -> dict:
    """Restart the Ollama systemd service."""
    try:
        result = subprocess.run(
            ["systemctl", "restart", OLLAMA_SERVICE],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            return {"ok": True, "message": "Ollama restarted successfully"}
        else:
            return {"ok": False, "error": result.stderr.strip() or "Restart failed"}
    except FileNotFoundError:
        return {"ok": False, "error": "systemctl not found — not running on systemd?"}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "Restart timed out"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


# ── HTTP Handler ──────────────────────────────────────

class DashboardHandler(BaseHTTPRequestHandler):

    def log_message(self, fmt, *args):
        """Override to suppress noisy request logs. Errors still print."""
        pass

    def send_json(self, data: dict, status: int = 200):
        """Send a JSON response."""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, file_path: Path, content_type: str = "text/html"):
        """Serve a static file."""
        try:
            body = file_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found")

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/" or path == "/index.html":
            self.send_file(DASHBOARD_DIR / "index.html")

        elif path == "/model-manager" or path == "/model-manager.html":
            self.send_file(DASHBOARD_DIR / "model-manager.html")

        elif path == "/agents" or path == "/agents.html":
            self.send_file(DASHBOARD_DIR / "agents.html")

        elif path == "/api/stats":
            self.send_json(get_system_stats())

        elif path in ("/api/models", "/api/models/installed"):
            self.send_json({"models": get_models()})

        elif path == "/api/models/available":
            self.send_json({"models": get_available_models()})

        else:
            # Try to serve as a static file (css, js, etc.)
            file_path = DASHBOARD_DIR / path.lstrip("/")
            if file_path.exists() and file_path.is_file():
                # Basic content type detection
                suffix = file_path.suffix
                types = {".css": "text/css", ".js": "application/javascript",
                         ".png": "image/png", ".svg": "image/svg+xml"}
                self.send_file(file_path, types.get(suffix, "application/octet-stream"))
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"404 Not Found")

    def do_POST(self):
        path = urlparse(self.path).path
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length) if content_length > 0 else b""

        try:
            payload = json.loads(body) if body else {}
        except json.JSONDecodeError:
            payload = {}

        if path in ("/api/pull", "/api/models/pull"):
            model = payload.get("model", "").strip()
            if not model:
                self.send_json({"ok": False, "error": "model name required"}, 400)
            else:
                self.send_json(pull_model(model))

        elif path == "/api/restart":
            self.send_json(restart_ollama())

        else:
            self.send_response(404)
            self.end_headers()

    def do_DELETE(self):
        path = urlparse(self.path).path
        # DELETE /api/models/<name>
        if path.startswith("/api/models/"):
            model_name = path[len("/api/models/"):]
            if model_name:
                self.send_json(delete_model(model_name))
            else:
                self.send_json({"ok": False, "error": "model name required"}, 400)
        else:
            self.send_response(404)
            self.end_headers()

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


# ── Main ──────────────────────────────────────────────

def main():
    print(f"AgentOS Dashboard starting on port {PORT}...")
    print(f"  Dashboard: http://localhost:{PORT}")
    print(f"  Stats API: http://localhost:{PORT}/api/stats")
    print(f"  GPU available: {GPU_AVAILABLE}")

    server = HTTPServer(("0.0.0.0", PORT), DashboardHandler)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard stopped.")
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
