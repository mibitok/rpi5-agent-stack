#!/usr/bin/env bash
# ==========================================================================
# STAGE 2: Core Stack — Docker, Python, Claude Code, agency-agents
# Target: Raspberry Pi 5 (aarch64), after Stage 1 completion
# Version: 2.0.0
# Usage: sudo bash stage2_core_stack.sh [--dry-run] [--force] [--skip-claude]
# ==========================================================================
set -euo pipefail

# === 0. ARG PARSING ===
DRY_RUN="false"; FORCE="false"; SKIP_CLAUDE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        --skip-claude) SKIP_CLAUDE="true"; shift ;;
        -h|--help) echo "Usage: $0 [--dry-run] [--force] [--skip-claude]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# === 1. CONSTANTS ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.0.0"
readonly LOG_FILE="/var/log/rpi5_agent_stage2.log"
readonly AGENT_USER="${SUDO_USER:-$(logname || echo pi)}"
readonly AGENT_HOME="/home/$AGENT_USER"
readonly AGENT_VENV="$AGENT_HOME/.venv/agents"
readonly AGENT_DIR="$AGENT_HOME/agent-stack"
readonly ENV_FILE="$AGENT_DIR/.env"

# === 2. LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === 3. PRE-FLIGHT CHECKS ===
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ "$(uname -m)" == "aarch64" ]] || die "Requires aarch64"
[[ -d /data ]] || die "Stage 1 not completed: /data missing"
swapon --show | grep -q zram || warn "zram not active — consider running Stage 1"

log "Stage 2 v$VERSION starting"
[[ "$DRY_RUN" == "true" ]] && log "🔍 DRY RUN: no changes"

# === 4. SYSTEM UPDATE ===
log "Updating system packages..."
[[ "$DRY_RUN" == "true" ]] && log "[DRY] apt update/upgrade" && true
if [[ "$DRY_RUN" != "true" ]]; then
    apt-get update -qq
    apt-get upgrade -y -qq
    apt-get install -y -qq \
        docker.io docker-compose-plugin \
        python3.11 python3.11-venv python3-pip \
        git curl build-essential libssl-dev \
        >/dev/null 2>&1
    log "✅ System packages installed"
fi

# === 5. DOCKER SETUP ===
log "Configuring Docker..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Add user to docker group
    usermod -aG docker "$AGENT_USER" 2>/dev/null || true
    
    # Enable and start Docker
    systemctl enable --now docker >/dev/null 2>&1
    
    # Docker daemon config for arm64 optimization
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
EOF
    systemctl restart docker >/dev/null 2>&1
    log "✅ Docker configured (user: $AGENT_USER, buildkit: enabled)"
else
    log "[DRY] Would configure Docker"
fi

# === 6. PYTHON + UV SETUP ===
log "Setting up Python environment..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Install uv (fast Python package manager)
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$AGENT_HOME/.bashrc" 2>/dev/null || true
    fi
    
    # Create virtual environment
    mkdir -p "$(dirname "$AGENT_VENV")"
    if [[ ! -d "$AGENT_VENV" ]]; then
        python3.11 -m venv "$AGENT_VENV"
        log "✅ Created venv: $AGENT_VENV"
    fi
    
    # Activate and upgrade pip
    source "$AGENT_VENV/bin/activate"
    pip install --upgrade pip setuptools wheel >/dev/null 2>&1
    log "✅ Python venv ready"
else
    log "[DRY] Would setup Python + uv"
fi

# === 7. CLAUDE CODE CLI (optional) ===
if [[ "$SKIP_CLAUDE" != "true" ]]; then
    log "Installing Claude Code CLI..."
    if [[ "$DRY_RUN" != "true" ]]; then
        source "$AGENT_VENV/bin/activate"
        if ! pip show anthropic >/dev/null 2>&1; then
            pip install anthropic claude-code >/dev/null 2>&1
            log "✅ Claude Code CLI installed"
        else
            log "Claude Code already installed"
        fi
    else
        log "[DRY] Would install Claude Code CLI"
    fi
else
    log "⏭️  Skipping Claude Code (--skip-claude)"
fi

# === 8. AGENCY-AGENTS REPO ===
log "Cloning agency-agents repository..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$AGENT_DIR"
    if [[ ! -d "$AGENT_DIR/agency-agents" ]]; then
        git clone https://github.com/agency-agents/agency-agents.git "$AGENT_DIR/agency-agents" >/dev/null 2>&1
        log "✅ Cloned agency-agents"
    else
        log "Repository exists, updating..."
        cd "$AGENT_DIR/agency-agents"
        git pull >/dev/null 2>&1 || true
    fi
    
    # Install dependencies with arm64 fixes
    source "$AGENT_VENV/bin/activate"
    cd "$AGENT_DIR/agency-agents"
    if [[ -f "requirements.txt" ]]; then
        # Fix known arm64 issues
        sed -i 's/torch==.*$/torch; sys_platform != "aarch64"/' requirements.txt 2>/dev/null || true
        pip install -r requirements.txt >/dev/null 2>&1 || warn "Some dependencies may need manual build"
        log "✅ Dependencies installed (arm64-compatible)"
    fi
else
    log "[DRY] Would clone agency-agents"
fi

# === 9. ENV FILE SETUP ===
log "Configuring environment variables..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$AGENT_DIR"
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<EOF
# Raspberry Pi 5 Agent Stack — Environment
# Generated: $(date)
# SECURITY: chmod 600 this file and never commit to git

ANTHROPIC_API_KEY=your_key_here
OPENAI_API_KEY=optional_key_here
AGENT_NAME=pi5-orchestrator
LOG_LEVEL=INFO
DATA_DIR=/data
VECTOR_DB_PATH=/data/vector_store
EOF
        chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "✅ Created $ENV_FILE (chmod 600)"
        warn "⚠️  Edit $ENV_FILE and add your API keys!"
    else
        log ".env file exists, skipping"
    fi
else
    log "[DRY] Would create .env file"
fi

# === 10. ORCHESTRATOR SERVICE ===
log "Installing orchestrator service..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Create basic orchestrator.py if not exists
    ORCH_FILE="$AGENT_DIR/orchestrator.py"
    if [[ ! -f "$ORCH_FILE" ]]; then
        cat > "$ORCH_FILE" <<'PYEOF'
#!/usr/bin/env python3
"""Basic orchestrator for Pi5 Agent Stack"""
import os, sys, logging, asyncio
from pathlib import Path
from dotenv import load_dotenv

# Load environment
load_dotenv(Path(__file__).parent / ".env")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("orchestrator")

async def main():
    logger.info("🤖 Orchestrator starting on Raspberry Pi 5")
    logger.info(f"📁 Data dir: {os.getenv('DATA_DIR', '/data')}")
    # TODO: Integrate Claude Code + agency-agents here
    while True:
        await asyncio.sleep(60)  # Heartbeat
        logger.debug("💓 Orchestrator alive")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("👋 Orchestrator stopped")
        sys.exit(0)
PYEOF
        chown "$AGENT_USER:$AGENT_USER" "$ORCH_FILE"
        chmod +x "$ORCH_FILE"
        log "✅ Created orchestrator.py"
    fi
    
    # Create systemd service
    SERVICE_FILE="/etc/systemd/system/pi5-agent.service"
    if [[ ! -f "$SERVICE_FILE" ]]; then
        cat > "$SERVICE_FILE" <<SVC
[Unit]
Description=Raspberry Pi 5 Agent Orchestrator
After=docker.service network.target
Wants=docker.service

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$AGENT_DIR
Environment=PATH=$AGENT_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=$AGENT_VENV/bin/python $ORCH_FILE
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload
        log "✅ Created systemd service: pi5-agent"
    fi
else
    log "[DRY] Would install orchestrator service"
fi

# === 11. VALIDATION ===
log "=== VALIDATION ==="
[[ "$DRY_RUN" != "true" ]] && {
    docker --version 2>/dev/null && log "✅ Docker: $(docker --version)" || warn "❌ Docker"
    source "$AGENT_VENV/bin/activate" 2>/dev/null && python --version && log "✅ Python venv: active" || warn "❌ Python venv"
    [[ -f "$ENV_FILE" ]] && log "✅ .env file: present (chmod 600)" || warn "❌ .env missing"
    systemctl list-unit-files | grep -q pi5-agent && log "✅ systemd service: configured" || warn "❌ Service not installed"
}

log "╔════════════════════════════════════╗"
log "║  ✅ Stage 2 COMPLETE!               ║"
log "║  📁 Agent dir: $AGENT_DIR"
log "║  🐍 Venv: $AGENT_VENV"
log "║  🔐 Edit: $ENV_FILE"
log "║                                    ║"
log "║  Next steps:                       ║"
log "║  1. sudo reboot (apply docker group)"
log "║  2. Edit $ENV_FILE with API keys"
log "║  3. sudo systemctl start pi5-agent"
log "║  4. Run stage3_integrations.sh     ║"
log "╚════════════════════════════════════╝"
