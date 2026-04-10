#!/usr/bin/env bash
# ==========================================================================
# STAGE 1: System Validation, Storage Prep, Swap & Network Share
# Target: Raspberry Pi 5 (aarch64), Raspberry Pi OS / Ubuntu 24.04
# Version: 1.1.0 (Interactive Mode Selection)
# Usage: sudo bash stage1_system_prep.sh [--mode=a|b] [--target=DEV] [--swap-type=file|zram|none] [--dry-run] [--force]
# ==========================================================================
set -euo pipefail

# === CONFIGURATION ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.1.0"
readonly LOG_FILE="/var/log/rpi5_agent_stage1.log"
readonly DATA_MOUNT="/data"
readonly SAMBA_SHARE="agent_workspace"
readonly SAMBA_PATH="/data/workspace"
readonly DEFAULT_SWAP_SIZE_GB=4
readonly FORCE="${FORCE:-false}"
readonly DRY_RUN="${DRY_RUN:-false}"

# === PARSING ARGS ===
MODE="${MODE:-}"
TARGET_DISK="${TARGET_DISK:-}"
SWAP_TYPE="${SWAP_TYPE:-auto}"  # file | zram | none | auto
ALLOW_ROOT="${ALLOW_ROOT:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=a|--mode=A) MODE="production"; shift ;;
        --mode=b|--mode=B) MODE="testing"; shift ;;
        --target=*) TARGET_DISK="${1#*=}"; shift ;;
        --swap-type=*) SWAP_TYPE="${1#*=}"; shift ;;
        --allow-root-partition) ALLOW_ROOT="true"; shift ;;
        --dry-run) DRY_RUN="true"; shift ;;
        --force) FORCE="true"; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# === LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === SAFETY CHECKS ===
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
[[ "$(uname -m)" == "aarch64" ]] || die "Requires aarch64. Detected: $(uname -m)"
command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1 || die "Failed to install jq"; }

log "Starting Stage 1: System Prep v$VERSION"
[[ "$DRY_RUN" == "true" ]] && { log "🔍 DRY RUN MODE: No destructive changes"; }

# === 1. SYSTEM VALIDATION ===
log "Checking hardware & OS..."
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
log "Detected RAM: ${RAM_GB}GB"
[[ "$RAM_GB" -lt 4 ]] && warn "⚠️ Less than 4GB RAM may cause issues with AI agents"

ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's|/dev/||' | sed 's|p*[0-9]*$||')
log "Root disk: $ROOT_DISK"

ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || die "No internet connection"

# === 2. STORAGE DETECTION ===
log "Scanning block devices..."

parse_size_to_gb() {
    local input="$1" num unit
    num=$(echo "$input" | grep -oE '^[0-9.]+' | head -1) || return 1
    unit=$(echo "$input" | grep -oE '[KMGTP]i?$' | tr -d 'i' | tr '[:lower:]' '[:upper:]') || unit=""
    [[ -z "$unit" ]] && { printf "%.0f" "$num" 2>/dev/null || echo "0"; return 0; }
    case "$unit" in
        K) echo "$num / 1048576" | bc -l 2>/dev/null || echo "0" ;;
        M) echo "$num / 1024" | bc -l 2>/dev/null || echo "0" ;;
        G) printf "%.0f" "$num" 2>/dev/null || echo "0" ;;
        T) echo "$num * 1024" | bc -l 2>/dev/null || echo "0" ;;
        *) echo "0" ;;
    esac
}

# Get candidate drives (non-root, type=disk, ro=0, size>=10GB)
readarray -t CANDIDATE_DRIVES < <(lsblk -dn -o NAME,SIZE,TYPE,RO 2>/dev/null | while read -r name size type ro; do
    [[ "$name" == "$ROOT_DISK" ]] && continue
    [[ "$type" != "disk" ]] && continue
    [[ "$ro" != "0" ]] && continue
    size_gb=$(parse_size_to_gb "$size") || continue
    [[ -z "$size_gb" || "$size_gb" -lt 10 ]] && continue
    echo "$name ${size_gb}G"
done)

# === 3. INTERACTIVE MODE SELECTION ===
if [[ -z "$MODE" ]]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    echo "║  🎯 Raspberry Pi 5 Agent Stack — Stage 1 Setup         ║"
    echo "╠════════════════════════════════════════════════════════╣"
    echo "║  Detected: $(uname -m), ${RAM_GB}GB RAM, root=$ROOT_DISK"
    echo "║  Candidate external drives: ${CANDIDATE_DRIVES[*]:-none}"
    echo "╠════════════════════════════════════════════════════════╣"
    echo "║  Выберите режим установки:                              ║"
    echo "║                                                        ║"
    echo "║  [A] 🏭 Production (рекомендуется)                     ║"
    echo "║      • Требуется NVMe/SSD диск                         ║"
    echo "║      • Swap на быстром носителе (файл)                 ║"
    echo "║      • Максимальная надёжность и производительность   ║"
    echo "║                                                        ║"
    echo "║  [B] 🧪 Testing (только для отладки!)                  ║"
    echo "║      • Работаем на текущей SD-карте                   ║"
    echo "║      • Swap в оперативной памяти (zram)               ║"
    echo "║      • ⚠️ SD-карта может износиться быстрее!          ║"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""
    
    if [[ "${CANDIDATE_DRIVES[*]}" == "none" ]]; then
        echo "⚠️  Внешний диск не обнаружен. Режим [A] недоступен."
        echo ""
        read -rp "Продолжить в режиме [B] (Testing)? [y/N]: " CONFIRM
        [[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted. Подключите NVMe/SSD для режима Production."
        MODE="testing"
        log "Auto-selected mode: testing (no external drive found)"
    else
        read -rp "Введите A или B: " CHOICE
        case "$CHOICE" in
            [Aa]) MODE="production" ;;
            [Bb]) 
                echo "⚠️  Вы выбрали режим Testing. SD-карта может износиться."
                read -rp "Подтверждаете риск? [y/N]: " CONFIRM
                [[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted."
                MODE="testing" 
                ;;
            *) die "Invalid choice. Use --mode=a or --mode=b" ;;
        esac
        log "Selected mode: $MODE"
    fi
else
    log "Mode specified via argument: $MODE"
fi

# === 4. TARGET SELECTION ===
if [[ "$MODE" == "production" ]]; then
    if [[ -n "$TARGET_DISK" ]]; then
        # Validate provided target
        if ! lsblk -n "$TARGET_DISK" >/dev/null 2>&1; then
            die "Target device $TARGET_DISK not found"
        fi
        if [[ "$TARGET_DISK" == "$ROOT_DISK" ]]; then
            die "SECURITY: Cannot use root disk $ROOT_DISK for production data"
        fi
        TARGET_DEV="$TARGET_DISK"
        log "Using specified target: $TARGET_DEV"
    elif [[ ${#CANDIDATE_DRIVES[@]} -gt 0 ]]; then
        TARGET_DEV=$(echo "${CANDIDATE_DRIVES[0]}" | awk '{print $1}')
        log "Auto-selected target: $TARGET_DEV"
    else
        die "Production mode requires external storage. Connect NVMe/SSD or use --mode=b for testing."
    fi
    
    # Determine swap type
    [[ "$SWAP_TYPE" == "auto" ]] && SWAP_TYPE="file"
    [[ "$SWAP_TYPE" != "file" ]] && warn "Production mode works best with --swap-type=file"
    
elif [[ "$MODE" == "testing" ]]; then
    TARGET_DEV="$ROOT_DISK"
    DATA_MOUNT="/data"  # Directory on root filesystem
    [[ "$SWAP_TYPE" == "auto" ]] && SWAP_TYPE="zram"
    log "Testing mode: using root disk $TARGET_DEV, swap=$SWAP_TYPE"
    warn "⚠️ Testing mode: avoid heavy write workloads to preserve SD card"
fi

# Confirm before destructive operations
if [[ "$FORCE" != "true" && "$DRY_RUN" != "true" && "$MODE" == "production" ]]; then
    read -rp "⚠️  Will format $TARGET_DEV. Continue? [y/N]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Yy] ]] || die "Aborted by user."
fi

# === 5. PREPARE /data ===
if [[ "$MODE" == "production" ]]; then
    PARTITION="${TARGET_DEV}1"
    if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        log "$DATA_MOUNT already mounted. Skipping format."
    else
        log "Formatting $TARGET_DEV -> ext4"
        [[ "$DRY_RUN" == "true" ]] && log "[DRY] Would run: wipefs/mkfs on $PARTITION" && true
        if [[ "$DRY_RUN" != "true" ]]; then
            wipefs -a "$TARGET_DEV" >/dev/null 2>&1 || true
            echo "type=83" | sfdisk "$TARGET_DEV" >/dev/null 2>&1
            udevadm settle
            mkfs.ext4 -F -L agent_data "$PARTITION" >/dev/null 2>&1
            mkdir -p "$DATA_MOUNT"
            grep -q "$PARTITION" /etc/fstab || echo "$PARTITION $DATA_MOUNT ext4 defaults,noatime,discard 0 2" >> /etc/fstab
            mount "$DATA_MOUNT"
            chown -R $(logname || echo "pi"):$(logname || echo "pi") "$DATA_MOUNT"
            log "Mounted $PARTITION at $DATA_MOUNT"
        fi
    fi
else
    # Testing mode: just ensure directory exists
    mkdir -p "$DATA_MOUNT"
    log "Created data directory: $DATA_MOUNT (on root filesystem)"
fi

# === 6. SWAP SETUP ===
if [[ "$SWAP_TYPE" == "zram" ]]; then
    log "Configuring zram swap (${RAM_GB}GB, compressed)..."
    [[ "$DRY_RUN" == "true" ]] && log "[DRY] Would configure zram" && true
    if [[ "$DRY_RUN" != "true" ]]; then
        apt-get install -y -qq zram-tools >/dev/null 2>&1
        cat > /etc/default/zramswap <<EOF
ALGO=zstd
PERCENT=50
EOF
        systemctl enable --now zramswap >/dev/null 2>&1
        echo "vm.swappiness=100" > /etc/sysctl.d/99-ai-swap.conf
        sysctl -p /etc/sysctl.d/99-ai-swap.conf >/dev/null
        log "✅ zram swap enabled (prioritizes RAM, compressed)"
    fi
elif [[ "$SWAP_TYPE" == "file" && "$MODE" == "production" ]]; then
    SWAP_FILE="$DATA_MOUNT/swapfile"
    if swapon --show | grep -q "$SWAP_FILE" 2>/dev/null; then
        log "Swap file already active."
    else
        log "Creating ${DEFAULT_SWAP_SIZE_GB}GB swap file on $DATA_MOUNT..."
        [[ "$DRY_RUN" == "true" ]] && log "[DRY] Would create swapfile" && true
        if [[ "$DRY_RUN" != "true" ]]; then
            fallocate -l ${DEFAULT_SWAP_SIZE_GB}G "$SWAP_FILE"
            chmod 600 "$SWAP_FILE"
            mkswap "$SWAP_FILE" >/dev/null 2>&1
            swapon "$SWAP_FILE"
            grep -q "$SWAP_FILE" /etc/fstab || echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
            echo "vm.swappiness=10" > /etc/sysctl.d/99-ai-swap.conf
            sysctl -p /etc/sysctl.d/99-ai-swap.conf >/dev/null
            log "✅ Swap file enabled. Swappiness=10 (prefer RAM)"
        fi
    fi
elif [[ "$SWAP_TYPE" == "none" ]]; then
    log "⚠️ Swap disabled per request. Monitor RAM usage carefully."
else
    warn "Unknown swap type: $SWAP_TYPE. Using system defaults."
fi

# === 7. SAMBA SHARE ===
log "Configuring Samba share..."
apt-get install -y -qq samba >/dev/null 2>&1
mkdir -p "$SAMBA_PATH"
chmod -R 775 "$SAMBA_PATH"
chown -R nobody:nogroup "$SAMBA_PATH"

SAMBA_CONF="/etc/samba/smb.conf"
if ! grep -q "\[$SAMBA_SHARE\]" "$SAMBA_CONF"; then
    cat <<EOF >> "$SAMBA_CONF"

[$SAMBA_SHARE]
   path = $SAMBA_PATH
   browseable = yes
   writable = yes
   guest ok = no
   create mask = 0775
   directory mask = 0775
   force user = $(logname || echo "pi")
   comment = Pi5 Agent Workspace [${MODE^^}]
EOF
    log "Samba config added. Set password: sudo smbpasswd -a $(logname || echo 'pi')"
    systemctl enable --now smbd nmbd >/dev/null 2>&1
else
    log "Samba share already configured."
fi

# === 8. VALIDATION ===
log "=== POST-SETUP VALIDATION ==="
df -h "$DATA_MOUNT" 2>/dev/null | tail -n +2 || true
swapon --show 2>/dev/null || true
systemctl is-active smbd >/dev/null 2>&1 && log "✅ Samba: Active" || warn "❌ Samba: Inactive"

log "╔════════════════════════════════════════════════════════╗"
log "║  ✅ Stage 1 completed successfully!                    ║"
log "║  Mode: ${MODE^^}                                          ║"
log "║  Data: $DATA_MOUNT"
log "║  Swap: $SWAP_TYPE"
log "║                                                        ║"
log "║  Next: sudo reboot && run stage2_core_stack.sh         ║"
log "╚════════════════════════════════════════════════════════╝"
