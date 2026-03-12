#!/bin/bash
# AgentOS - First Boot Setup
# Runs once on first boot via the agentos-first-boot systemd service.
# Calls detect-gpu.sh, then install-ai-stack.sh, then disables itself.

set -e  # Exit on error
set -u  # Exit on undefined variable

LOG_FILE="/var/log/agentos/first-boot.log"
AGENTOS_DIR="/opt/agentos"

# ── Helpers ───────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "${msg}"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ── Banner ────────────────────────────────────────────
print_banner() {
    echo ""
    echo " █████╗  ██████╗ ███████╗███╗   ██╗████████╗  ██████╗ ███████╗"
    echo "██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══  ██╔═══██╗██╔════╝"
    echo "███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║    ██║   ██║███████╗"
    echo "██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║    ██║   ██║╚════██║"
    echo "██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║    ╚██████╔╝███████║"
    echo "╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚══════╝"
    echo ""
    echo "  First Boot Setup — this will take a few minutes."
    echo "  Log: ${LOG_FILE}"
    echo ""
}

# ── Preflight ─────────────────────────────────────────
preflight() {
    mkdir -p /var/log/agentos
    log "=== AgentOS First Boot Started ==="
    log "Hostname: $(hostname)"
    log "IP: $(hostname -I | awk '{print $1}' || echo 'not yet assigned')"

    # Ensure scripts are executable
    chmod +x "${AGENTOS_DIR}/scripts/"*.sh
}

# ── Wait for network ──────────────────────────────────
# The install scripts need internet access (Ollama, pip)
wait_for_network() {
    log "⏳ Waiting for network..."
    local attempts=0
    until ping -c 1 -W 2 8.8.8.8 > /dev/null 2>&1; do
        sleep 3
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 20 ]; then
            log "⚠  Network not available after 60s — proceeding anyway (offline installs will fail)"
            return
        fi
    done
    log "✅ Network ready"
}

# ── GPU setup ─────────────────────────────────────────
setup_gpu() {
    log "--- GPU Detection ---"
    bash "${AGENTOS_DIR}/scripts/detect-gpu.sh" || {
        log "⚠  GPU detection encountered an error — continuing without GPU"
    }
}

# ── AI stack install ──────────────────────────────────
install_ai_stack() {
    log "--- AI Stack Install ---"
    bash "${AGENTOS_DIR}/scripts/install-ai-stack.sh"
}

# ── Done ─────────────────────────────────────────────
print_ready() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")

    log "=== AgentOS First Boot Complete ==="

    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║  ✅  AgentOS is READY!                       ║"
    echo "╠══════════════════════════════════════════════╣"
    echo "║                                              ║"
    echo "║  From any browser on your network:           ║"
    echo "║                                              ║"
    echo "║  Dashboard:  http://${ip}:3000               ║"
    echo "║  Chat UI:    http://${ip}:8080               ║"
    echo "║  Ollama API: http://${ip}:11434              ║"
    echo "║                                              ║"
    echo "║  Login: username=agent  password=agentos     ║"
    echo "║                                              ║"
    echo "║  First model download is running in the      ║"
    echo "║  background. Check the dashboard for status. ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

# ── Main ─────────────────────────────────────────────
print_banner
preflight
wait_for_network
setup_gpu
install_ai_stack
print_ready
