#!/usr/bin/env bash
# ==========================================================================
# STAGE 2: Core Stack — Docker, Python, Claude Code, agency-agents
# Target: Raspberry Pi 5 (aarch64), Ubuntu 24.04 / Raspberry Pi OS
# Version: 2.1.0 (Fixed: Ubuntu 24.04 compatibility, error handling)
# Usage: sudo bash stage2_core_stack.sh [--dry-run] [--force] [--skip-claude] [--repo=URL]
# ==========================================================================
set -euo pipefail

# === 0. ARG PARSING ===
DRY_RUN="false"; FORCE="false"; SKIP_CLAUDE="false"
AGENCY_REPO="${AGENCY_REPO:-https://github.com/agency-agents/framework.git}"  # configurable

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        --skip-claude) SKIP_CLAUDE="true"; shift ;;
        --repo=*) AGENCY_REPO="${1#*=}"; shift ;;
        -h|--help) echo "Usage: $0 [--dry-run] [--force] [--skip-claude] [--repo=URL]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# === 1. CONSTANTS ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.1.0"
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
[[ -d /data ]] || warn "/data not found — Stage 1 may not be complete"

log "Stage 2 v$VERSION starting"
[[ "$DRY_RUN" == "true" ]] && log "🔍 DRY RUN: no changes"

# === 4. SYSTEM UPDATE & BASE PACKAGES ===
log "Updating system and installing base packages..."
if [[ "$DRY_RUN" != "true" ]]; then
    apt-get update -qq
    apt-get install -y -qq \
        git curl wget build-essential libssl-dev \
        python3 python3-pip python3-venv \
        >/dev/null 2>&1 || warn "Some packages may need manual install"
    log "✅ Base packages installed"
else
    log "[DRY] Would update system"
fi

# === 5. DOCKER SETUP (Ubuntu 24.04 compatible) ===
log "Configuring Docker..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Install Docker (Ubuntu way)
    if ! command -v docker >/dev/null 2>&1; then
        apt-get install -y -qq docker.io docker-compose >/dev/null 2>&1 || {
            warn "Docker install failed, trying snap..."
            snap install docker 2>/dev/null || warn "Docker installation failed"
        }
    fi
    
    # Add user to docker group
    usermod -aG docker "$AGENT_USER" 2>/dev/null || true
    
    # Enable Docker
    systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable docker service"
    
    # Docker config for arm64
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF' 2>/dev/null || true
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
EOF
    systemctl restart docker >/dev/null 2>&1 || true
    log "✅ Docker configured"
else
    log "[DRY] Would configure Docker"
fi

# === 6. PYTHON ENV SETUP ===
log "Setting up Python environment..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Detect Python version
    PYTHON_CMD=$(command -v python3.11 || command -v python3 || echo "")
    [[ -z "$PYTHON_CMD" ]] && die "Python 3 not found. Install python3 or python3.11"
    log "Using Python: $PYTHON_CMD"
    
    # Install uv if not present
    if ! command -v uv >/dev/null 2>&1; then
        curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || {
            warn "uv install failed, using pip instead"
        }
        # Add to PATH for current session
        export PATH="$AGENT_HOME/.local/bin:$PATH"
    fi
    
    # Create venv
    mkdir -p "$(dirname "$AGENT_VENV")"
    if [[ ! -d "$AGENT_VENV" ]]; then
        "$PYTHON_CMD" -m venv "$AGENT_VENV"
        log "✅ Created venv: $AGENT_VENV"
    fi
    
    # Activate and upgrade
    source "$AGENT_VENV/bin/activate"
    pip install --upgrade pip setuptools wheel >/dev/null 2>&1
    log "✅ Python venv ready"
else
    log "[DRY] Would setup Python environment"
fi

# === 7. CLAUDE CODE CLI (optional) ===
if [[ "$SKIP_CLAUDE" != "true" ]]; then
    log "Installing Claude/Anthropic SDK..."
    if [[ "$DRY_RUN" != "true" ]]; then
        source "$AGENT_VENV/bin/activate" 2>/dev/null || true
        if ! pip show anthropic >/dev/null 2>&1; then
            pip install anthropic >/dev/null 2>&1 && log "✅ Anthropic SDK installed" || warn "Could not install anthropic"
        else
            log "Anthropic SDK already installed"
        fi
    else
        log "[DRY] Would install Claude SDK"
    fi
else
    log "⏭️ Skipping Claude SDK (--skip-claude)"
fi

# === 8. AGENCY-AGENTS REPO ===
log "Cloning agency framework repository..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$AGENT_DIR"
    REPO_NAME=$(basename "$AGENCY_REPO" .git)
    REPO_PATH="$AGENT_DIR/$REPO_NAME"
    
    if [[ ! -d "$REPO_PATH" ]]; then
        # Try clone with timeout
        if git clone --depth 1 --timeout 30 "$AGENCY_REPO" "$REPO_PATH" >/dev/null 2>&1; then
            log "✅ Cloned: $AGENCY_REPO"
        else
            warn "Could not clone $AGENCY_REPO"
            log "💡 Tip: Use --repo=URL to specify a different repository"
            log "💡 Or clone manually: git clone $AGENCY_REPO $REPO_PATH"
        fi
    else
        log "Repository exists at $REPO_PATH"
        cd "$REPO_PATH" && git pull --quiet >/dev/null 2>&1 || true
    fi
    
    # Install dependencies if requirements.txt exists
    if [[ -f "$REPO_PATH/requirements.txt" ]]; then
        source "$AGENT_VENV/bin/activate" 2>/dev/null || true
        cd "$REPO_PATH"
        # Filter out problematic packages for arm64
        grep -vE "^torch|^tensorflow" requirements.txt > requirements.arm64.txt 2>/dev/null || cp requirements.txt requirements.arm64.txt
        pip install -r requirements.arm64.txt >/dev/null 2>&1 && log "✅ Dependencies installed" || warn "Some dependencies may need manual build"
    fi
else
    log "[DRY] Would clone repository"
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

ANTHROPIC_API_KEY=sk-ant-api03-xxxxxxxxxxxxxxxxxxxx
OPENAI_API_KEY=optional_key_here
AGENT_NAME=pi5-orchestrator
LOG_LEVEL=INFO
DATA_DIR=/data
VECTOR_DB_PATH=/data/vector_store
EOF
        chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "✅ Created $ENV_FILE (chmod 600)"
        warn "⚠️ Edit $ENV_FILE and add your actual API keys!"
    else
        log ".env file exists, skipping"
    fi
else
    log "[DRY] Would create .env file"
fi

# === 10. ORCHESTRATOR SERVICE ===
log "Installing orchestrator service..."
if [[ "$DRY_RUN" != "true" ]]; then
    ORCH_FILE="$AGENT_DIR/orchestrator.py"
    if [[ ! -f "$ORCH_FILE" ]]; then
        cat > "$ORCH_FILE" <<'PYEOF'
#!/usr/bin/env python3
"""Basic orchestrator for Pi5 Agent Stack"""
import os, sys, logging, asyncio
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("orchestrator")

async def main():
    logger.info("🤖 Orchestrator starting on Raspberry Pi 5")
    logger.info(f"📁 Data dir: {os.getenv('DATA_DIR', '/data')}")
    while True:
        await asyncio.sleep(60)
        logger.debug("💓 Orchestrator heartbeat")

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
    
    # Systemd service
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
        systemctl daemon-reload >/dev/null 2>&1
        log "✅ Created systemd service: pi5-agent"
    fi
else
    log "[DRY] Would install orchestrator service"
fi

# === 11. VALIDATION ===
log "=== VALIDATION ==="
if [[ "$DRY_RUN" != "true" ]]; then
    command -v docker >/dev/null 2>&1 && log "✅ Docker: $(docker --version 2>/dev/null)" || warn "❌ Docker not ready"
    if source "$AGENT_VENV/bin/activate" 2>/dev/null; then
        python --version 2>/dev/null && log "✅ Python venv: active" || warn "❌ Python venv"
    else
        warn "❌ Could not activate venv"
    fi
    [[ -f "$ENV_FILE" ]] && log "✅ .env: present (chmod 600)" || warn "❌ .env missing"
    systemctl list-unit-files pi5-agent.service 2>/dev/null | grep -q enabled && log "✅ Service: configured" || warn "⏳ Service: not enabled"
fi

log "╔════════════════════════════════════╗"
log "║  ✅ Stage 2 COMPLETE!               ║"
log "║  📁 Agent dir: $AGENT_DIR"
log "║  🐍 Venv: $AGENT_VENV"
log "║  🔐 Edit: $ENV_FILE"
log "║                                    ║"
log "║  Next:                              ║"
log "║  1. sudo reboot (apply docker group)"
log "║  2. Edit $ENV_FILE with API keys"
log "║  3. sudo systemctl start pi5-agent"
log "║  4. Run stage3_integrations.sh     ║"
log "╚════════════════════════════════════╝"
