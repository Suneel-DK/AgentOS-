# Contributing to AgentOS

Thanks for wanting to help. AgentOS is a small project right now and every contribution matters.

---

## What We're Building

AgentOS is an OS you flash to a machine and boot — your entire AI stack (Ollama + Open WebUI + dashboard) is ready with zero setup. Think TrueNAS but for local AI.

The simplest contributions right now:
- **Bug reports** — if something doesn't work, open an issue
- **Hardware testing** — boot the ISO on your machine and report what happens
- **Shell scripts** — improve `first-boot.sh`, `detect-gpu.sh`, `health-check.sh`
- **New agent templates** — add a `.py` file to `agents/templates/`
- **Dashboard improvements** — HTML/CSS/JS only, no build step

---

## Project Structure

```
AgentOS/
├── build/
│   ├── build.sh          # Builds the bootable ISO
│   ├── preseed.cfg       # Ubuntu autoinstall config (zero-touch install)
│   └── grub.cfg          # GRUB boot menu
├── config/
│   └── packages.list     # Packages pre-installed in the OS
├── scripts/
│   ├── first-boot.sh     # Runs once on first boot
│   ├── detect-gpu.sh     # Auto GPU detection (NVIDIA / AMD / CPU)
│   ├── install-ai-stack.sh  # Installs Ollama + Open WebUI
│   ├── update.sh         # Updates all components in-place
│   └── health-check.sh   # Verifies everything is running
├── dashboard/
│   ├── server.py         # Python HTTP server, port 3000
│   ├── index.html        # Main dashboard UI
│   ├── model-manager.html   # Browse + install Ollama models
│   ├── agents.html       # Launch and monitor agents
│   └── dashboard.service # Systemd service file
├── agents/
│   ├── agent-runner.py   # Agent lifecycle API, port 3001
│   ├── agents.service    # Systemd service file
│   └── templates/        # Example agent scripts
└── docs/
    └── CONTRIBUTING.md   # This file
```

---

## How to Run Locally (Without a Real Machine)

You don't need to build the ISO to work on most things.

### Dashboard (server + UI)

```bash
# Install Python deps
pip3 install psutil pynvml

# Start the dashboard server
python3 dashboard/server.py

# Open in browser
open http://localhost:3000
```

### Agent Runner

```bash
# In a separate terminal
python3 agents/agent-runner.py

# Then open the agents page
open http://localhost:3000/agents
```

### Testing the ISO build

You need a Linux machine (or VM) with `xorriso`:

```bash
sudo apt install xorriso wget
sudo bash build/build.sh
```

Then boot in QEMU:

```bash
sudo apt install qemu-system-x86_64
qemu-system-x86_64 -m 4096 -cdrom AgentOS-0.1.0.iso -boot d -enable-kvm
```

---

## Coding Rules

Follow the style you see in existing files. Quick summary:

**Shell scripts:**
- Always start with `set -e` and `set -u`
- Echo what you're doing before you do it
- Every function gets a one-line comment
- Use variables at the top, no hardcoded paths inside functions

```bash
#!/bin/bash
# AgentOS - Script Name
# One-line description

set -e
set -u

MY_DIR="/opt/agentos"

# Does the thing
do_thing() {
    echo "📦 Doing thing..."
    # code
    echo "✅ Thing done"
}
```

**Python:**
- Use stdlib where possible — no unnecessary dependencies
- One docstring per module and per function
- Handle `FileNotFoundError` and `subprocess.TimeoutExpired` everywhere you call external tools

```python
#!/usr/bin/env python3
"""
AgentOS - Module Name
One-line description.
"""

def main():
    pass

if __name__ == "__main__":
    main()
```

**HTML/CSS/JS:**
- No frameworks — vanilla JS only
- Match the existing dark terminal aesthetic (colors from CSS variables)
- `fetch()` for all API calls — no jQuery, no axios

---

## Adding an Agent Template

Create a `.py` file in `agents/templates/`. The agent runner will automatically discover it.

Rules for templates:
- Must be a standalone Python script (no imports beyond stdlib + psutil)
- Must print output with `flush=True` so logs appear in real time
- Should handle `KeyboardInterrupt` or just let it propagate (the runner catches it)
- If interactive, read from `sys.stdin` line by line

Example minimal template:

```python
#!/usr/bin/env python3
"""
AgentOS Template — My Agent
What this agent does in one sentence.
"""
import time, sys

print("[my-agent] Starting...", flush=True)

while True:
    print("[my-agent] tick", flush=True)
    time.sleep(10)
```

Place it at `agents/templates/my-agent.py` and it will appear in the UI automatically.

---

## Commit Message Format

```
feat: add AMD ROCm detection in detect-gpu.sh
fix: correct path in first-boot.sh
docs: update CONTRIBUTING with template guide
chore: bump llama3.2 to latest in packages.list
```

- `feat:` — new functionality
- `fix:` — bug fix
- `docs:` — documentation only
- `chore:` — maintenance, deps, config

Keep the subject line under 72 characters. No period at the end.

---

## Opening Issues

Use GitHub Issues: https://github.com/Suneel-DK/AgentOS/issues

When reporting a bug, include:
- What you did
- What you expected
- What actually happened
- Output of `bash /opt/agentos/scripts/health-check.sh` (if on a live system)
- Your hardware (CPU, GPU, RAM)

---

## Pull Requests

1. Fork the repo
2. Create a branch: `git checkout -b feat/my-thing`
3. Make your changes
4. Test it (run health-check.sh on a real or virtual machine if possible)
5. Open a PR with a clear title and description

Keep PRs focused — one thing per PR is easier to review than five things.

---

## Questions

Open a GitHub Discussion or an Issue. This is a small project and we're happy to help.
