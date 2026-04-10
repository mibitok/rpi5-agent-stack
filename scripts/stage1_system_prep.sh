#!/usr/bin/env bash
# ==========================================================================
# STAGE 1: System Validation, Storage Prep, Swap & Network Share
# Target: Raspberry Pi 5 (aarch64), Raspberry Pi OS / Ubuntu 24.04
# Version: 1.1.2 (Fixed: no readonly on configurable vars)
# Usage: sudo bash stage1_system_prep.sh [--mode=a|b] [--target=DEV] [--swap-type=file|zram|none] [--dry-run] [--force]
# ==========================================================================
set -euo pipefail

# === 0. PARSE ARGUMENTS FIRST ===
MODE=""
TARGET_DISK=""
SWAP_TYPE="auto"
DRY_RUN="false"
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=a|--mode=A) MODE="production"; shift ;;
        --mode=b|--mode=B) MODE="testing"; shift ;;
        --target=*) TARGET_DISK="${1#*=}"; shift ;;
        --swap-type=*) SWAP_TYPE="${1#*=}"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        -h|--help) echo "Usage: $0 [--mode=a|b] [--target=DEV] [--swap-type=file|zram|none] [--dry-run] [--force]"; exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# === 1. CONSTANTS (truly readonly) ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.1.2"
readonly LOG_FILE="/var/log/rpi5_agent_stage1.log"
readonly SAMBA_SHARE="agent_workspace"
readonly DEFAULT_SWAP_SIZE_GB=4

# === 2. CONFIGURABLE VARS (not readonly) ===
DATA_MOUNT="/data"
SAMBA_PATH="/data/workspace"

# === 3. LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === 4. SAFETY CHECKS ===
[[ $EUID -eq 0 ]] || die "Run with sudo"
[[ "$(uname -m)" == "aarch64" ]] || die "Requires aarch64"
command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1; }

log "Stage 1 v$VERSION starting"
[[ "$DRY_RUN" == "true" ]] && log "🔍 DRY RUN: no changes"

# === 5. SYSTEM INFO ===
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's|/dev/||' | sed 's|p*[0-9]*$||')
log "RAM: ${RAM_GB}GB | Root: $ROOT_DISK"
ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || warn "Network check failed"

# === 6. STORAGE DETECTION ===
parse_size_gb() {
    local s="$1" n u
    n=$(echo "$s" | grep -oE '^[0-9.]+') || return 1
    u=$(echo "$s" | grep -oE '[KMGTP]i?$' | tr -d 'i' | tr '[:lower:]' '[:upper:]') || u=""
    case "$u" in
        K) echo "$n/1048576" | bc -l 2>/dev/null || echo 0 ;;
        M) echo "$n/1024" | bc -l 2>/dev/null || echo 0 ;;
        G|"") printf "%.0f" "$n" 2>/dev/null || echo 0 ;;
        T) echo "$n*1024" | bc -l 2>/dev/null || echo 0 ;;
        *) echo 0 ;;
    esac
}

readarray -t CANDIDATES < <(lsblk -dn -o NAME,SIZE,TYPE,RO 2>/dev/null | while read -r name size type ro; do
    [[ "$name" == "$ROOT_DISK" || "$type" != "disk" || "$ro" != "0" ]] && continue
    gb=$(parse_size_gb "$size") || continue
    [[ -z "$gb" || "$gb" -lt 10 ]] && continue
    echo "$name ${gb}G"
done)

# === 7. MODE SELECTION ===
if [[ -z "$MODE" ]]; then
    echo -e "\n╔════════════════════════════╗\n║  🎯 Pi5 Agent Stack — Stage 1  ║\n╠════════════════════════════╣"
    echo "║  RAM: ${RAM_GB}GB | Root: $ROOT_DISK"
    echo "║  External: ${CANDIDATES[*]:-none}"
    echo "╠════════════════════════════╣\n║  [A] 🏭 Production (NVMe/SSD)\n║  [B] 🧪 Testing (SD + zram)\n╚════════════════════════════╝\n"
    if [[ "${CANDIDATES[*]:-none}" == "none" ]]; then
        read -rp "No external disk. Continue in [B]? [y/N]: " c; [[ "$c" =~ ^[Yy] ]] || die "Aborted"
        MODE="testing"
    else
        read -rp "Select A or B: " c
        case "$c" in [Aa]) MODE="production";; [Bb]) read -rp "⚠️ Confirm SD wear risk? [y/N]: " r; [[ "$r" =~ ^[Yy] ]] || die "Aborted"; MODE="testing";; *) die "Invalid";; esac
    fi
fi
log "Mode: $MODE"

# === 8. RESOLVE TARGET & SWAP ===
if [[ "$MODE" == "production" ]]; then
    if [[ -n "$TARGET_DISK" ]]; then
        lsblk -n "$TARGET_DISK" >/dev/null || die "Target $TARGET_DISK not found"
        [[ "$TARGET_DISK" == "$ROOT_DISK" ]] && die "Cannot use root disk for production"
        TARGET_DEV="$TARGET_DISK"
    elif [[ ${#CANDIDATES[@]} -gt 0 ]]; then
        TARGET_DEV=$(echo "${CANDIDATES[0]}" | awk '{print $1}')
    else
        die "Production needs external disk. Use --mode=b or connect NVMe/SSD"
    fi
    [[ "$SWAP_TYPE" == "auto" ]] && SWAP_TYPE="file"
    log "Production: target=$TARGET_DEV swap=$SWAP_TYPE"
else
    TARGET_DEV="$ROOT_DISK"
    [[ "$SWAP_TYPE" == "auto" ]] && SWAP_TYPE="zram"
    log "Testing: root=$TARGET_DEV swap=$SWAP_TYPE"
    warn "⚠️ Testing mode: limit writes to preserve SD"
fi

# Confirm before format
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" && "$MODE" == "production" ]]; then
    read -rp "⚠️ Format $TARGET_DEV? [y/N]: " c; [[ "$c" =~ ^[Yy] ]] || die "Aborted"
fi

# === 9. PREPARE /data ===
if [[ "$MODE" == "production" && "$DRY_RUN" != "true" ]]; then
    PART="${TARGET_DEV}1"
    if ! mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        log "Formatting $TARGET_DEV"
        wipefs -a "$TARGET_DEV" >/dev/null 2>&1 || true
        echo "type=83" | sfdisk "$TARGET_DEV" >/dev/null 2>&1
        udevadm settle
        mkfs.ext4 -F -L agent_data "$PART" >/dev/null 2>&1
        mkdir -p "$DATA_MOUNT"
        grep -q "$PART" /etc/fstab || echo "$PART $DATA_MOUNT ext4 defaults,noatime,discard 0 2" >> /etc/fstab
        mount "$DATA_MOUNT"
        chown -R $(logname || echo pi):$(logname || echo pi) "$DATA_MOUNT"
        log "Mounted $PART at $DATA_MOUNT"
    fi
else
    mkdir -p "$DATA_MOUNT"
    [[ "$DRY_RUN" != "true" ]] && log "Created $DATA_MOUNT"
fi

# === 10. SWAP ===
if [[ "$SWAP_TYPE" == "zram" && "$DRY_RUN" != "true" ]]; then
    log "Setting up zram..."
    apt-get install -y -qq zram-tools >/dev/null 2>&1 || true
    echo -e "ALGO=zstd\nPERCENT=50" > /etc/default/zramswap
    systemctl enable --now zramswap >/dev/null 2>&1 || true
    echo "vm.swappiness=100" > /etc/sysctl.d/99-ai-swap.conf
    sysctl -p /etc/sysctl.d/99-ai-swap.conf >/dev/null 2>&1 || true
    log "✅ zram active"
elif [[ "$SWAP_TYPE" == "file" && "$MODE" == "production" && "$DRY_RUN" != "true" ]]; then
    SWAP_F="$DATA_MOUNT/swapfile"
    if ! swapon --show | grep -q "$SWAP_F" 2>/dev/null; then
        log "Creating ${DEFAULT_SWAP_SIZE_GB}G swap..."
        fallocate -l ${DEFAULT_SWAP_SIZE_GB}G "$SWAP_F"
        chmod 600 "$SWAP_F"; mkswap "$SWAP_F" >/dev/null; swapon "$SWAP_F"
        grep -q "$SWAP_F" /etc/fstab || echo "$SWAP_F none swap sw 0 0" >> /etc/fstab
        echo "vm.swappiness=10" > /etc/sysctl.d/99-ai-swap.conf
        sysctl -p /etc/sysctl.d/99-ai-swap.conf >/dev/null 2>&1 || true
        log "✅ swap file active"
    fi
elif [[ "$SWAP_TYPE" == "none" ]]; then
    log "⚠️ Swap disabled"
fi

# === 11. SAMBA ===
log "Configuring Samba..."
apt-get install -y -qq samba >/dev/null 2>&1 || true
mkdir -p "$SAMBA_PATH"; chmod -R 775 "$SAMBA_PATH"; chown -R nobody:nogroup "$SAMBA_PATH"
if ! grep -q "\[$SAMBA_SHARE\]" /etc/samba/smb.conf; then
    cat >> /etc/samba/smb.conf <<EOF

[$SAMBA_SHARE]
   path = $SAMBA_PATH
   browseable = yes
   writable = yes
   guest ok = no
   create mask = 0775
   directory mask = 0775
   force user = $(logname || echo pi)
   comment = Pi5 Agent [${MODE^^}]
EOF
    log "Samba config added. Set password: sudo smbpasswd -a $(logname || echo pi)"
    systemctl enable --now smbd nmbd >/dev/null 2>&1 || true
fi

# === 12. VALIDATION ===
log "=== VALIDATION ==="
df -h "$DATA_MOUNT" 2>/dev/null | tail -1 || true
swapon --show 2>/dev/null || true
systemctl is-active smbd >/dev/null 2>&1 && log "✅ Samba: Active" || warn "❌ Samba"

log "╔════════════════════════════════╗"
log "║  ✅ Stage 1 DONE | Mode: ${MODE^^}  ║"
log "║  Data: $DATA_MOUNT | Swap: $SWAP_TYPE"
log "║  Next: sudo reboot && stage2   ║"
log "╚════════════════════════════════╝"
