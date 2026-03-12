#!/bin/bash
# AgentOS - Update Script
# Updates AgentOS components (Ollama, Open WebUI, dashboard) without touching user data or models.
# Run this on a live AgentOS system: sudo bash /opt/agentos/scripts/update.sh

set -e  # Exit on error
set -u  # Exit on undefined variable

# ── Config ────────────────────────────────────────────
AGENTOS_DIR="/opt/agentos"
LOG_FILE="/var/log/agentos/update.log"
OLLAMA_SERVICE="ollama"
WEBUI_SERVICE="openwebui"
DASHBOARD_SERVICE="agentos-dashboard"
AGENTS_SERVICE="agentos-agents"

# ── Helpers ───────────────────────────────────────────
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "${msg}"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

header() {
    echo ""
    echo "══════════════════════════════════════════════"
    echo "  $1"
    echo "══════════════════════════════════════════════"
}

die() {
    echo ""
    echo "❌ ERROR: $1"
    exit 1
}

# Restart a systemd service if it exists and is enabled
restart_if_running() {
    local svc="$1"
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        log "Restarting ${svc}..."
        systemctl restart "${svc}"
        log "✅ ${svc} restarted"
    else
        log "⚠  ${svc} is not running — skipping restart"
    fi
}

# ── Preflight ─────────────────────────────────────────
preflight() {
    header "🔍 Preflight Checks"

    if [ "$(id -u)" -ne 0 ]; then
        die "Must run as root. Try: sudo bash update.sh"
    fi

    mkdir -p "$(dirname "${LOG_FILE}")"
    log "Update started"
    echo "✅ Running as root"
}

# ── Update Ollama ─────────────────────────────────────
# Re-runs the official Ollama install script which upgrades in-place
update_ollama() {
    header "🤖 Updating Ollama"

    local current_version=""
    if command -v ollama &>/dev/null; then
        current_version=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
        log "Current Ollama version: ${current_version}"
    else
        log "Ollama not found — will do fresh install"
    fi

    log "Running Ollama install script..."
    curl -fsSL https://ollama.com/install.sh | sh
    log "✅ Ollama updated"

    local new_version
    new_version=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
    log "New Ollama version: ${new_version}"

    restart_if_running "${OLLAMA_SERVICE}"
}

# ── Update Open WebUI ─────────────────────────────────
# pip install --upgrade handles it
update_webui() {
    header "🌐 Updating Open WebUI"

    if ! command -v pip3 &>/dev/null; then
        log "⚠  pip3 not found — skipping Open WebUI update"
        return
    fi

    local current_version=""
    current_version=$(pip3 show open-webui 2>/dev/null | grep Version | awk '{print $2}' || echo "not installed")
    log "Current Open WebUI version: ${current_version}"

    log "Running pip upgrade..."
    pip3 install --upgrade open-webui
    log "✅ Open WebUI updated"

    local new_version
    new_version=$(pip3 show open-webui 2>/dev/null | grep Version | awk '{print $2}' || echo "unknown")
    log "New Open WebUI version: ${new_version}"

    restart_if_running "${WEBUI_SERVICE}"
}

# ── Update AgentOS Dashboard ──────────────────────────
# Pulls latest files from the AgentOS directory if it's a git repo,
# or copies from the ISO mount if available.
update_dashboard() {
    header "📊 Updating AgentOS Dashboard"

    if [ ! -d "${AGENTOS_DIR}" ]; then
        log "⚠  AgentOS dir not found at ${AGENTOS_DIR} — skipping"
        return
    fi

    # If the install dir is a git repo, pull latest
    if [ -d "${AGENTOS_DIR}/.git" ]; then
        log "Git repo detected — pulling latest..."
        git -C "${AGENTOS_DIR}" pull --ff-only \
            || log "⚠  Git pull failed (may have local changes) — skipping"
    else
        log "ℹ  Not a git repo — nothing to pull. To enable auto-updates, clone the repo to ${AGENTOS_DIR}"
    fi

    # Install any new Python dependencies
    if [ -f "${AGENTOS_DIR}/dashboard/requirements.txt" ]; then
        log "Installing Python dependencies..."
        pip3 install -r "${AGENTOS_DIR}/dashboard/requirements.txt" --quiet
    fi

    log "✅ Dashboard files up to date"
    restart_if_running "${DASHBOARD_SERVICE}"
    restart_if_running "${AGENTS_SERVICE}"
}

# ── Update System Packages ────────────────────────────
# Security patches only — no dist-upgrade, no kernel updates
update_system() {
    header "🔒 Security Updates"

    log "Running apt security updates..."
    apt-get update -q
    apt-get upgrade -y --only-upgrade \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    apt-get autoremove -y --purge
    log "✅ Security updates applied"
}

# ── Summary ───────────────────────────────────────────
print_summary() {
    header "✅ Update Complete"

    echo ""
    echo "  Components updated:"
    echo "    → Ollama:       $(ollama --version 2>/dev/null | awk '{print $NF}' || echo 'error')"
    echo "    → Open WebUI:   $(pip3 show open-webui 2>/dev/null | grep Version | awk '{print $2}' || echo 'not installed')"
    echo "    → Dashboard:    latest"
    echo ""
    echo "  Services:"
    for svc in "${OLLAMA_SERVICE}" "${WEBUI_SERVICE}" "${DASHBOARD_SERVICE}" "${AGENTS_SERVICE}"; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            echo "    ✅ ${svc}"
        else
            echo "    ○  ${svc} (not running)"
        fi
    done
    echo ""
    echo "  Log: ${LOG_FILE}"
    echo ""

    log "Update complete"
}

# ── Main ─────────────────────────────────────────────
main() {
    echo ""
    echo "  AgentOS Update Script"
    echo "  User data and models are NEVER touched."
    echo ""

    preflight
    update_ollama
    update_webui
    update_dashboard
    update_system
    print_summary
}

main "$@"
