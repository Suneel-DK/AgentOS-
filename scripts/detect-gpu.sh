#!/bin/bash
# AgentOS - GPU Detection Script
# Detects NVIDIA, AMD, or CPU-only hardware and installs the right drivers.
# Respects AGENTOS_NO_GPU=1 (set by Safe Mode GRUB entry).

set -e  # Exit on error
set -u  # Exit on undefined variable

LOG_FILE="/var/log/agentos/gpu-detect.log"

# ── Helpers ───────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "${msg}"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ── Update package lists ──────────────────────────────
# Must run before any apt-get install
update_packages() {
    log "📦 Updating package lists..."
    apt-get update -q
    log "✅ Package lists updated"
}

# ── NVIDIA ────────────────────────────────────────────
# Uses ubuntu-drivers which picks the correct version for your card
install_nvidia() {
    log "📦 Installing NVIDIA drivers..."
    apt-get install -y ubuntu-drivers-common
    ubuntu-drivers autoinstall
    log "✅ NVIDIA drivers installed"
    log "ℹ  A reboot is required for GPU drivers to load"
    log "ℹ  AgentOS will reboot automatically after first-boot setup"
}

# ── AMD ───────────────────────────────────────────────
install_amd() {
    log "📦 Installing AMD ROCm drivers..."
    # Add ROCm apt repo
    apt-get install -y wget gnupg
    wget -q -O - https://repo.radeon.com/rocm/rocm.gpg.key | apt-key add -
    echo "deb [arch=amd64] https://repo.radeon.com/rocm/apt/debian/ focal main" \
        > /etc/apt/sources.list.d/rocm.list
    apt-get update -q
    apt-get install -y rocm-dkms
    usermod -a -G render,video agent 2>/dev/null || true
    log "✅ AMD ROCm installed"
}

# ── CPU Only ──────────────────────────────────────────
install_cpu_only() {
    log "ℹ  Setting up CPU-only mode"
    log "ℹ  AI will run slower without a GPU — but everything will still work"
    log "ℹ  Recommended models for CPU: llama3.2:1b, gemma2:2b, phi3:mini"
}

# ── Detection ─────────────────────────────────────────
# Checks for Safe Mode flag first, then hardware
detect_gpu() {
    log "🔍 Detecting GPU hardware..."

    # Safe Mode: GRUB passes AGENTOS_NO_GPU=1 on the kernel command line
    if grep -q "AGENTOS_NO_GPU=1" /proc/cmdline 2>/dev/null; then
        log "⚠  Safe Mode active — skipping GPU driver install"
        install_cpu_only
        return
    fi

    # Check for NVIDIA — match VGA/3D controller lines specifically
    if lspci | grep -E "VGA|3D controller|Display" | grep -qi "nvidia"; then
        log "✅ NVIDIA GPU detected"
        lspci | grep -E "VGA|3D controller|Display" | grep -i "nvidia" | while read -r line; do
            log "   → ${line}"
        done
        update_packages
        install_nvidia

    # Check for AMD GPU — match display controller lines, not AMD CPUs
    elif lspci | grep -E "VGA|3D controller|Display" | grep -qiE "amd|radeon|advanced micro devices.*\[amd"; then
        log "✅ AMD GPU detected"
        lspci | grep -E "VGA|3D controller|Display" | grep -iE "amd|radeon" | while read -r line; do
            log "   → ${line}"
        done
        update_packages
        install_amd

    else
        log "⚠  No discrete GPU detected — running in CPU-only mode"
        install_cpu_only
    fi
}

# ── Main ─────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"
log "=== GPU detection started ==="
detect_gpu
log "=== GPU detection complete ==="
