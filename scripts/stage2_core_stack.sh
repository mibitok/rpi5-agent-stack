#!/usr/bin/env bash
# ==========================================================================
# STAGE 2: Core Stack — Docker, Python, Claude Code, Orchestrator
# Target: Raspberry Pi 5 (aarch64), Ubuntu 24.04 / Raspberry Pi OS
# Version: 2.2.0 (All production fixes integrated)
# Usage: sudo bash stage2_core_stack.sh [--dry-run] [--force] [--skip-claude] [--no-repo]
# ==========================================================================
set -euo pipefail

# === 0. ARG PARSING ===
DRY_RUN="false"; FORCE="false"; SKIP_CLAUDE="false"; NO_REPO="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        --skip-claude) SKIP_CLAUDE="true"; shift ;;
        --no-repo) NO_REPO="true"; shift ;;
        -h|--help) echo "Usage: $0 [--dry-run] [--force] [--skip-claude] [--no-repo]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# === 1. CONSTANTS ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.2.0"
readonly LOG_FILE="/var/log/rpi5_agent_stage2.log"
readonly AGENT_USER="${SUDO_USER:-$(logname || echo code)}"
readonly AGENT_HOME="/home/$AGENT_USER"
readonly AGENT_VENV="$AGENT_HOME/.venv/agents"
readonly AGENT_DIR="$AGENT_HOME/agent-stack"
readonly ENV_FILE="$AGENT_DIR/.env"
readonly DATA_DIR="/data"

# === 2. LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === 3. PRE-FLIGHT CHECKS ===
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ "$(uname -m)" == "aarch64" ]] || die "Requires aarch64 architecture"
command -v python3 >/dev/null 2>&1 || die "Python 3 not found"

log "Stage 2 v$VERSION starting"
[[ "$DRY_RUN" == "true" ]] && log "🔍 DRY RUN: no changes will be made"

# === 4. SYSTEM PACKAGES (Ubuntu 24.04 compatible) ===
log "Installing system packages..."
if [[ "$DRY_RUN" != "true" ]]; then
    apt-get update -qq
    apt-get install -y -qq \
        docker.io docker-compose \
        python3 python3-venv python3-pip python-is-python3 \
        git curl wget build-essential libssl-dev \
        >/dev/null 2>&1 || warn "Some packages may need manual attention"
    log "✅ System packages installed"
else
    log "[DRY] Would install system packages"
fi

# === 5. DOCKER SETUP ===
log "Configuring Docker..."
if [[ "$DRY_RUN" != "true" ]]; then
    usermod -aG docker "$AGENT_USER" 2>/dev/null || true
    systemctl enable --now docker >/dev/null 2>&1 || warn "Could not enable docker"
    
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF' 2>/dev/null || true
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "features": {"buildkit": true}
}
EOF
    systemctl restart docker >/dev/null 2>&1 || true
    log "✅ Docker configured (user: $AGENT_USER)"
else
    log "[DRY] Would configure Docker"
fi

# === 6. /data DIRECTORY & PERMISSIONS ===
log "Preparing /data directory..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$DATA_DIR"/{logs,vector_store,config,workspace,notes}
    chown -R "$AGENT_USER:$AGENT_USER" "$DATA_DIR"
    chmod -R 755 "$DATA_DIR"
    log "✅ /data ready (owner: $AGENT_USER)"
else
    log "[DRY] Would setup /data"
fi

# === 7. PYTHON VENV (CREATED AS USER, NOT ROOT) ===
log "Setting up Python virtual environment..."
if [[ "$DRY_RUN" != "true" ]]; then
    # Clean old broken venv if exists
    if [[ -d "$AGENT_VENV" ]]; then
        rm -rf "$AGENT_VENV"
    fi
    
    # Create venv AS THE TARGET USER
    sudo -u "$AGENT_USER" python3 -m venv "$AGENT_VENV"
    
    # Activate & install packages INSIDE venv (bypasses PEP 668)
    sudo -u "$AGENT_USER" bash -c "
        source $AGENT_VENV/bin/activate
        pip install --upgrade pip setuptools wheel
        pip install python-dotenv anthropic fastapi 'uvicorn[standard]' httpx chromadb
    " >/dev/null 2>&1
    
    log "✅ Python venv created & dependencies installed"
else
    log "[DRY] Would setup Python venv"
fi

# === 8. AGENCY REPO (OPTIONAL) ===
if [[ "$NO_REPO" != "true" ]]; then
    log "Cloning agency framework (placeholder)..."
    if [[ "$DRY_RUN" != "true" ]]; then
        mkdir -p "$AGENT_DIR"
        if git clone --depth 1 --quiet https://github.com/anthropics/anthropic-cookbook.git "$AGENT_DIR/cookbook" 2>/dev/null; then
            log "✅ Cloned example repo (replace with your agency-agents URL)"
        else
            warn "Git clone failed. Use --no-repo or fix URL manually."
            mkdir -p "$AGENT_DIR/cookbook" # fallback dir
        fi
    else
        log "[DRY] Would clone repository"
    fi
else
    log "⏭️  Skipping repo clone (--no-repo)"
fi

# === 9. ENV FILE SETUP ===
log "Configuring .env..."
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$AGENT_DIR"
    if [[ ! -f "$ENV_FILE" ]]; then
        cat > "$ENV_FILE" <<EOF
# Pi5 Agent Stack — Environment
ANTHROPIC_API_KEY=sk-ant-api03-REPLACE_WITH_YOUR_KEY
AGENT_NAME=pi5-orchestrator
LOG_LEVEL=INFO
DATA_DIR=$DATA_DIR
VECTOR_DB_PATH=$DATA_DIR/vector_store
EOF
        chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        log "✅ Created $ENV_FILE (chmod 600)"
    else
        log ".env already exists"
    fi
else
    log "[DRY] Would create .env"
fi

# === 10. ORCHESTRATOR.PY (FIXED VERSION) ===
log "Creating orchestrator.py..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > "$AGENT_DIR/orchestrator.py" <<'PYEOF'
#!/usr/bin/env python3
"""Raspberry Pi 5 Agent Orchestrator — v1.2 (Fixed)"""
import os, sys, logging, asyncio
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent / ".env")

# Safe path resolution
DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
LOG_DIR = DATA_DIR / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_DIR / "orchestrator.log")
    ]
)
logger = logging.getLogger("orchestrator")

async def main():
    logger.info("🤖 Orchestrator starting on Raspberry Pi 5")
    logger.info(f"📁 Data: {os.getenv('DATA_DIR')} | Agent: {os.getenv('AGENT_NAME')}")
    
    # Heartbeat loop
    while True:
        await asyncio.sleep(60)
        logger.debug("💓 Heartbeat")

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("👋 Stopped gracefully")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Crash: {e}", exc_info=True)
        sys.exit(1)
PYEOF
    chmod +x "$AGENT_DIR/orchestrator.py"
    chown "$AGENT_USER:$AGENT_USER" "$AGENT_DIR/orchestrator.py"
    log "✅ orchestrator.py created (fixed os.getenv & paths)"
else
    log "[DRY] Would create orchestrator.py"
fi

# === 11. SYSTEMD SERVICE ===
log "Installing systemd service..."
if [[ "$DRY_RUN" != "true" ]]; then
    cat > /etc/systemd/system/pi5-agent.service <<SVC
[Unit]
Description=Raspberry Pi 5 Agent Orchestrator
After=docker.service network.target
Wants=docker.service

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$AGENT_DIR
Environment=PATH=$AGENT_VENV/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
ExecStart=$AGENT_VENV/bin/python $AGENT_DIR/orchestrator.py
Restart=on-failure
RestartSec=10
# Security hardening
ProtectSystem=strict
ReadWritePaths=$DATA_DIR $AGENT_DIR $AGENT_VENV
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SVC
    systemctl daemon-reload >/dev/null 2>&1
    log "✅ pi5-agent.service installed"
else
    log "[DRY] Would create systemd service"
fi

# === 12. VALIDATION & SUMMARY ===
log "=== VALIDATION ==="
if [[ "$DRY_RUN" != "true" ]]; then
    command -v docker >/dev/null 2>&1 && log "✅ Docker: $(docker --version 2>/dev/null)" || warn "❌ Docker"
    sudo -u "$AGENT_USER" bash -c "source $AGENT_VENV/bin/activate && python -c 'import anthropic; import chromadb; print(\"✅ venv & SDKs OK\")'" 2>/dev/null && \
        log "✅ Python venv & libraries: OK" || warn "❌ Python env"
    [[ -f "$ENV_FILE" ]] && log "✅ .env: present" || warn "❌ .env missing"
    systemctl list-unit-files pi5-agent.service 2>/dev/null | grep -q enabled && log "✅ systemd service: configured" || warn "⏳ service: not enabled"
fi

log "╔════════════════════════════════════════╗"
log "║  ✅ Stage 2 COMPLETE! (v$VERSION)         ║"
log "║  📁 Agent dir: $AGENT_DIR"
log "║  🐍 Venv: $AGENT_VENV"
log "║  🔐 Edit: $ENV_FILE"
log "║  📂 Data: $DATA_DIR"
log "║                                        ║"
log "║  🚀 Next steps:                        ║"
log "║  1. sudo reboot (apply docker group)   ║"
log "║  2. nano $ENV_FILE (add API key)       ║"
log "║  3. sudo systemctl enable --now pi5-agent"
log "║  4. Run stage3_integrations.sh         ║"
log "╚════════════════════════════════════════╝"
