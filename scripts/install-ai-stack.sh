#!/bin/bash
# AgentOS - AI Stack Installer
# Installs Ollama, Open WebUI, and the AgentOS dashboard.
# Runs on first boot after GPU drivers are set up.

set -e  # Exit on error
set -u  # Exit on undefined variable

LOG_FILE="/var/log/agentos/install.log"
AGENTOS_DIR="/opt/agentos"

# ── Helpers ───────────────────────────────────────────
log() {
    local msg="[$(date '+%H:%M:%S')] $1"
    echo "${msg}"
    echo "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

# ── Ollama ────────────────────────────────────────────
# Uses the official install script — handles all architectures
install_ollama() {
    log "📦 Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    systemctl enable ollama
    systemctl start ollama
    # Wait for Ollama API to be ready before pulling models
    log "⏳ Waiting for Ollama API to start..."
    local attempts=0
    until curl -s http://localhost:11434 > /dev/null 2>&1; do
        sleep 2
        attempts=$((attempts + 1))
        if [ "${attempts}" -ge 30 ]; then
            log "⚠  Ollama API didn't start in 60s — continuing anyway"
            break
        fi
    done
    log "✅ Ollama installed and running"
}

# ── Open WebUI ────────────────────────────────────────
install_openwebui() {
    log "📦 Installing Open WebUI..."

    # Ensure pip3 and build dependencies are present
    apt-get install -y python3-pip python3-dev build-essential

    # Install into a dedicated virtualenv to avoid system Python conflicts
    python3 -m venv /opt/agentos-venv
    /opt/agentos-venv/bin/pip install --upgrade pip --quiet
    /opt/agentos-venv/bin/pip install open-webui --quiet

    # Create systemd service using the venv binary
    cat > /etc/systemd/system/openwebui.service << 'EOF'
[Unit]
Description=Open WebUI — AgentOS Chat Interface
Documentation=https://github.com/open-webui/open-webui
After=network.target ollama.service
Wants=ollama.service

[Service]
Type=simple
User=agent
Group=agent
WorkingDirectory=/opt/agentos
ExecStart=/opt/agentos-venv/bin/open-webui serve
Environment=OLLAMA_BASE_URL=http://localhost:11434
Environment=PORT=8080
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=openwebui

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable openwebui
    systemctl start openwebui
    log "✅ Open WebUI installed and running"
}

# ── Dashboard Python deps ─────────────────────────────
install_dashboard_deps() {
    log "📦 Installing dashboard Python dependencies..."
    # Install into system Python3 (dashboard runs as its own service)
    pip3 install psutil pynvml --quiet || \
        /opt/agentos-venv/bin/pip install psutil pynvml --quiet
    log "✅ Dashboard dependencies installed"
}

# ── Dashboard service ─────────────────────────────────
install_dashboard_service() {
    log "📦 Installing AgentOS Dashboard service..."
    cp "${AGENTOS_DIR}/dashboard/dashboard.service" \
        /etc/systemd/system/agentos-dashboard.service
    systemctl daemon-reload
    systemctl enable agentos-dashboard
    systemctl start agentos-dashboard
    log "✅ Dashboard service installed"
}

# ── Agent Runner service ──────────────────────────────
install_agents_service() {
    log "📦 Installing AgentOS Agent Runner service..."
    cp "${AGENTOS_DIR}/agents/agents.service" \
        /etc/systemd/system/agentos-agents.service
    systemctl daemon-reload
    systemctl enable agentos-agents
    systemctl start agentos-agents
    log "✅ Agent runner service installed"
}

# ── Default model ─────────────────────────────────────
pull_default_model() {
    log "📦 Pulling default AI model (llama3.2:3b)..."
    log "ℹ  This is ~2GB — may take a while on first boot"
    # Pull in background so first-boot finishes faster
    nohup ollama pull llama3.2:3b >> "${LOG_FILE}" 2>&1 &
    log "✅ Model download started in background (pid $!)"
    log "ℹ  Model will be ready in a few minutes — check dashboard for progress"
}

# ── Main ─────────────────────────────────────────────
mkdir -p "$(dirname "${LOG_FILE}")"
log "=== AI stack installation started ==="

install_ollama
install_openwebui
install_dashboard_deps
install_dashboard_service
install_agents_service
pull_default_model

log "=== AI stack installation complete ==="
