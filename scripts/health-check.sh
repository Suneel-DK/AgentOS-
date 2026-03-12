#!/bin/bash
# AgentOS - Health Check
# Verifies that all AgentOS services are running correctly.
# Prints a clean status report. Exit code 0 = healthy, 1 = issues found.
# Usage: bash /opt/agentos/scripts/health-check.sh

set -u  # Exit on undefined variable
# Note: no set -e here — we want to check everything even if some checks fail

# ── Config ────────────────────────────────────────────
OLLAMA_API="http://localhost:11434"
WEBUI_URL="http://localhost:8080"
DASHBOARD_URL="http://localhost:3000"
AGENTS_URL="http://localhost:3001"
TIMEOUT=5  # seconds per HTTP check

# ── State ─────────────────────────────────────────────
ISSUES=0

# ── Colors (disabled if not a terminal) ──────────────
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    DIM='\033[0;90m'
    RESET='\033[0m'
    BOLD='\033[1m'
else
    GREEN='' RED='' YELLOW='' BLUE='' DIM='' RESET='' BOLD=''
fi

# ── Helpers ───────────────────────────────────────────
pass() { echo -e "  ${GREEN}✅${RESET} $1"; }
fail() { echo -e "  ${RED}❌${RESET} $1"; ISSUES=$((ISSUES + 1)); }
warn() { echo -e "  ${YELLOW}⚠ ${RESET} $1"; }
info() { echo -e "  ${DIM}ℹ ${RESET} $1"; }

section() {
    echo ""
    echo -e "${BOLD}$1${RESET}"
    echo "  ──────────────────────────────────────────"
}

# Check if a systemd service is active
check_service() {
    local name="$1"
    local display="$2"
    if systemctl is-active --quiet "${name}" 2>/dev/null; then
        local uptime
        uptime=$(systemctl show "${name}" -p ActiveEnterTimestamp --value 2>/dev/null | \
                 awk '{print $2, $3}' || echo "unknown")
        pass "${display} — running (since ${uptime})"
        return 0
    else
        fail "${display} — NOT running"
        info "Fix: sudo systemctl start ${name}"
        return 1
    fi
}

# Check if an HTTP endpoint is reachable
check_http() {
    local url="$1"
    local display="$2"
    local expected_status="${3:-200}"

    local actual_status
    actual_status=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "${TIMEOUT}" "${url}" 2>/dev/null || echo "000")

    if [ "${actual_status}" = "${expected_status}" ] || [ "${actual_status}" = "200" ]; then
        pass "${display} — reachable (HTTP ${actual_status})"
        return 0
    else
        fail "${display} — not reachable (HTTP ${actual_status})"
        info "URL: ${url}"
        return 1
    fi
}

# Check if a port is listening
check_port() {
    local port="$1"
    local display="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port}" || \
       netstat -tlnp 2>/dev/null | grep -q ":${port}"; then
        pass "${display} — port ${port} is open"
        return 0
    else
        fail "${display} — port ${port} not listening"
        return 1
    fi
}

# ── Checks ────────────────────────────────────────────

check_system() {
    section "System"

    # OS
    local os_name
    os_name=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2 || echo "Unknown")
    info "OS: ${os_name}"

    # Uptime
    local uptime_str
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')
    info "Uptime: ${uptime_str}"

    # Disk space
    local disk_use
    disk_use=$(df -h / 2>/dev/null | awk 'NR==2 {print $5 " used (" $3 " / " $2 ")"}')
    local disk_pct
    disk_pct=$(df / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
    if [ "${disk_pct:-0}" -ge 90 ] 2>/dev/null; then
        fail "Disk space: ${disk_use} — WARNING: disk nearly full!"
    elif [ "${disk_pct:-0}" -ge 75 ] 2>/dev/null; then
        warn "Disk space: ${disk_use} — getting full"
    else
        pass "Disk space: ${disk_use}"
    fi

    # RAM
    local ram_info
    ram_info=$(free -h 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " used (" int($3/$2*100) "%)"}' 2>/dev/null || echo "unknown")
    info "RAM: ${ram_info}"

    # Network
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null 2>&1; then
        pass "Network — internet reachable"
    else
        warn "Network — internet unreachable (offline mode?)"
    fi
}

check_gpu() {
    section "GPU"

    if command -v nvidia-smi &>/dev/null; then
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
        local gpu_driver
        gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
        local gpu_vram
        gpu_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "Unknown")
        pass "NVIDIA GPU detected: ${gpu_name}"
        info "Driver: ${gpu_driver} · VRAM: ${gpu_vram}"
    elif lspci 2>/dev/null | grep -qi "amd\|radeon"; then
        local amd_name
        amd_name=$(lspci 2>/dev/null | grep -i "amd\|radeon" | head -1 | sed 's/.*: //')
        pass "AMD GPU detected: ${amd_name}"
        if command -v rocm-smi &>/dev/null; then
            info "ROCm drivers loaded"
        else
            warn "ROCm drivers not found — GPU acceleration may be unavailable"
        fi
    else
        warn "No GPU detected — running in CPU-only mode"
        info "AI inference will work but will be slower"
    fi
}

check_ollama() {
    section "Ollama (AI Runtime)"

    check_service "ollama" "Ollama systemd service"
    check_http "${OLLAMA_API}" "Ollama API"
    check_port "11434" "Ollama port"

    # List loaded models
    if command -v ollama &>/dev/null; then
        local version
        version=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
        info "Version: ${version}"

        local model_count
        model_count=$(ollama list 2>/dev/null | tail -n +2 | wc -l || echo "0")
        if [ "${model_count}" -eq 0 ]; then
            warn "No models installed. Run: ollama pull llama3.2:3b"
        else
            pass "${model_count} model(s) installed"
            ollama list 2>/dev/null | tail -n +2 | awk '{print "    → " $1}' || true
        fi
    fi
}

check_webui() {
    section "Open WebUI (Chat Interface)"

    check_service "openwebui" "Open WebUI systemd service"
    check_http "${WEBUI_URL}" "Open WebUI"
    check_port "8080" "Open WebUI port"
}

check_dashboard() {
    section "AgentOS Dashboard"

    check_service "agentos-dashboard" "Dashboard systemd service"
    check_http "${DASHBOARD_URL}" "Dashboard UI"
    check_port "3000" "Dashboard port"

    check_service "agentos-agents" "Agent runner service"
    check_http "${AGENTS_URL}/agents" "Agent runner API"
    check_port "3001" "Agent runner port"
}

check_scripts() {
    section "AgentOS Scripts"

    local scripts=(
        "/opt/agentos/scripts/first-boot.sh"
        "/opt/agentos/scripts/detect-gpu.sh"
        "/opt/agentos/scripts/install-ai-stack.sh"
        "/opt/agentos/scripts/update.sh"
        "/opt/agentos/scripts/health-check.sh"
    )

    for f in "${scripts[@]}"; do
        if [ -f "${f}" ] && [ -x "${f}" ]; then
            pass "$(basename ${f}) — present and executable"
        elif [ -f "${f}" ]; then
            warn "$(basename ${f}) — present but not executable (run: chmod +x ${f})"
        else
            fail "$(basename ${f}) — missing"
        fi
    done
}

# ── Summary ───────────────────────────────────────────
print_summary() {
    echo ""
    echo "══════════════════════════════════════════════"
    if [ "${ISSUES}" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}✅ All checks passed — AgentOS is healthy${RESET}"
    else
        echo -e "  ${RED}${BOLD}❌ ${ISSUES} issue(s) found — see above for details${RESET}"
    fi
    echo "══════════════════════════════════════════════"

    # Print useful URLs
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    echo ""
    echo "  Access your AgentOS:"
    echo -e "    ${BLUE}Dashboard:${RESET}  http://${ip}:3000"
    echo -e "    ${BLUE}Chat UI:${RESET}    http://${ip}:8080"
    echo -e "    ${BLUE}Ollama API:${RESET} http://${ip}:11434"
    echo ""
}

# ── Main ─────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}  AgentOS Health Check${RESET}"
    echo -e "  ${DIM}$(date)${RESET}"

    check_system
    check_gpu
    check_ollama
    check_webui
    check_dashboard
    check_scripts
    print_summary

    exit "${ISSUES}"
}

main "$@"
