# AgentOS

An open-source operating system built for AI — flash it, boot it, and your entire AI stack is ready. No setup, no terminal, no complexity.

> Think TrueNAS, but for running local AI models and agents.

---

## What It Does

Boot AgentOS on any x86 machine and get:

- **Ollama** — local AI model runtime (llama3.2 pre-loaded)
- **Open WebUI** — browser-based chat interface
- **AgentOS Dashboard** — live system stats, model manager, agent runner
- **Auto GPU detection** — NVIDIA CUDA and AMD ROCm drivers installed automatically
- **Zero-touch install** — boots, installs, and configures itself with no user input

---

## Quick Start

### Build the ISO

```bash
# Requires Ubuntu/Debian with sudo
cd build
sudo bash build.sh
```

Output: `build/AgentOS-0.1.0.iso`

### Flash to USB

Use [Balena Etcher](https://etcher.balena.io/) to flash the ISO to a USB drive.

### Boot

1. Insert USB, boot your machine
2. Select **"Install AgentOS v0.1.0"** from the GRUB menu
3. Installation runs automatically (~5 min)
4. On first boot, Ollama and Open WebUI install automatically (~10 min)

### Access

Once ready, open a browser on any device on your network:

| Service | URL |
|---|---|
| Dashboard | `http://<machine-ip>:3000` |
| Chat UI | `http://<machine-ip>:8080` |
| Ollama API | `http://<machine-ip>:11434` |

Default login: `agent` / `agentos`

---

## Test in a VM

```bash
# VirtualBox
# 1. Create VM: Linux, Ubuntu 64-bit, 4GB RAM, 20GB disk
# 2. Storage → attach AgentOS-0.1.0.iso
# 3. System → Boot Order: Optical first, EFI disabled
# 4. Start VM
```

---

## Project Structure

```
AgentOS/
├── build/
│   ├── build.sh          # ISO builder
│   ├── preseed.cfg        # Ubuntu autoinstall config (zero-touch)
│   └── grub.cfg           # Boot menu
├── scripts/
│   ├── first-boot.sh      # Runs on first boot
│   ├── detect-gpu.sh      # NVIDIA / AMD / CPU-only detection
│   ├── install-ai-stack.sh # Installs Ollama + Open WebUI
│   ├── update.sh          # Update AgentOS components
│   └── health-check.sh    # Check all services are running
├── dashboard/
│   ├── index.html         # Main dashboard
│   ├── server.py          # Dashboard API server (port 3000)
│   ├── model-manager.html # Model download/delete UI
│   └── agents.html        # Agent runner UI
├── agents/
│   └── agent-runner.py    # Agent process manager (port 3001)
├── config/
│   └── packages.list      # Pre-installed packages
└── docs/
    └── CONTRIBUTING.md
```

---

## Hardware Support

| GPU | Status |
|---|---|
| NVIDIA (CUDA) | ✅ Auto-detected, drivers installed |
| AMD (ROCm) | ✅ Auto-detected, drivers installed |
| CPU only | ✅ Works, slower inference |

Minimum specs: 4GB RAM, 20GB disk, x86-64 CPU

---

## Status

**v0.1.0** — First bootable ISO. All core components functional.

- [x] Bootable ISO (BIOS + EFI)
- [x] Zero-touch Ubuntu autoinstall
- [x] GPU auto-detection
- [x] Ollama + Open WebUI install
- [x] AgentOS dashboard with live stats
- [x] Model manager
- [x] Agent runner
- [ ] First public release

---

## Contributing

See [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for how to get started.

Issues and PRs welcome: [github.com/Suneel-DK/AgentOS](https://github.com/Suneel-DK/AgentOS)
