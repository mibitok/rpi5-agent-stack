#!/usr/bin/env bash
# ==========================================================================
# STAGE 1: System Validation, Storage Prep, Swap & Network Share
# Target: Raspberry Pi 5 (aarch64), Raspberry Pi OS / Ubuntu 24.04
# Version: 1.0.0
# Usage: sudo bash stage1_system_prep.sh [--dry-run] [--force]
# ==========================================================================
set -euo pipefail

# === CONFIGURATION ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"
readonly LOG_FILE="/var/log/rpi5_agent_stage1.log"
readonly DATA_MOUNT="/data"
readonly SAMBA_SHARE="agent_workspace"
readonly SAMBA_PATH="/data/workspace"
readonly SWAP_SIZE_GB=4
readonly FORCE="${FORCE:-false}"
readonly DRY_RUN="${DRY_RUN:-false}"

# === LOGGING ===
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"; }
warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2; }
die()   { log "FATAL: $1"; exit 1; }

# === SAFETY CHECKS ===
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0"
[[ "$(uname -m)" == "aarch64" ]] || die "Requires aarch64 architecture. Detected: $(uname -m)"
command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq jq >/dev/null 2>&1 || die "Failed to install jq"; }

log "Starting Stage 1: System Prep & Storage Setup v$VERSION"
[[ "$DRY_RUN" == "true" ]] && { log "DRY RUN MODE: No destructive changes will be made"; set -x; }

# === 1. SYSTEM VALIDATION ===
log "Checking hardware & OS..."
RAM_GB=$(free -g | awk '/^Mem:/{print $2}')
log "Detected RAM: ${RAM_GB}GB"
if ! grep -q "Raspberry Pi 5" /proc/device-tree/model 2>/dev/null; then
    warn "Not detected as Pi 5. Proceed with caution."
fi
log "Network connectivity test..."
ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || die "No internet connection. Aborting."

# === 2. STORAGE AUTO-DETECTION (SAFE & FIXED) ===
log "Scanning block devices..."

# Получаем имя корневого устройства (без /dev/ и без номера раздела)
ROOT_DISK=$(findmnt -n -o SOURCE / | sed 's|/dev/||' | sed 's|p*[0-9]*$||')
log "Root disk detected: $ROOT_DISK (will be excluded from formatting)"

# Функция: конвертирует человеческий размер (64G, 500M) в ГБ (число)
parse_size_to_gb() {
    local input="$1"
    local num unit
    # Извлекаем число и единицу
    num=$(echo "$input" | grep -oE '^[0-9.]+' | head -1)
    unit=$(echo "$input" | grep -oE '[KMGTP]i?$' | tr -d 'i' | tr '[:lower:]' '[:upper:]')
    
    # Если нет единицы — считаем, что это уже ГБ
    [[ -z "$unit" ]] && { printf "%.0f" "$num" 2>/dev/null || echo "0"; return; }
    
    case "$unit" in
        K) echo "$num / 1048576" | bc -l 2>/dev/null || echo "0" ;;
        M) echo "$num / 1024" | bc -l 2>/dev/null || echo "0" ;;
        G) printf "%.0f" "$num" 2>/dev/null || echo "0" ;;
        T) echo "$num * 1024" | bc -l 2>/dev/null || echo "0" ;;
        *) echo "0" ;;
    esac
}

# Сканируем диски: NAME, SIZE (human), TYPE, RO
readarray -t DRIVES < <(lsblk -dn -o NAME,SIZE,TYPE,RO 2>/dev/null | while read -r name size type ro; do
    # Пропускаем корневой диск
    [[ "$name" == "$ROOT_DISK" ]] && continue
    # Только type=disk
    [[ "$type" != "disk" ]] && continue
    # Только read-write (RO=0)
    [[ "$ro" != "0" ]] && continue
    # Конвертируем размер и фильтруем <10 ГБ
    size_gb=$(parse_size_to_gb "$size")
    [[ -z "$size_gb" || "$size_gb" -lt 10 ]] && continue
    
    echo "$name ${size_gb}G"
done)

# Логирование для отладки
log "Detected candidate drives: ${DRIVES[*]:-none}"

if [[ ${#DRIVES[@]} -eq 0 ]]; then
    log "=== Available block devices ==="
    lsblk -o NAME,SIZE,TYPE,RO,MOUNTPOINT 2>/dev/null | tee -a "$LOG_FILE"
    log "==============================="
    die "No suitable external storage (>10GB, read-write, type=disk, non-root) found. Connect NVMe/SSD/USB."
fi

TARGET_DEV=$(echo "${DRIVES[0]}" | awk '{print $1}')
TARGET_SIZE=$(echo "${DRIVES[0]}" | awk '{print $2}')
log "✅ Selected storage for formatting: $TARGET_DEV ($TARGET_SIZE)"

# Дополнительная защита: явный запрет на системные устройства
case "$TARGET_DEV" in
    mmcblk0|mmcblk1|sda|nvme0n1)
        if [[ "$TARGET_DEV" == "$ROOT_DISK" ]]; then
            die "SECURITY: Refusing to format root device $TARGET_DEV. Aborting."
        fi
        ;;
esac
# === 3. FORMAT & MOUNT ===
PARTITION="${TARGET_DEV}1"
if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
    log "$DATA_MOUNT already mounted. Skipping format/mount."
else
    log "Partitioning and formatting $TARGET_DEV -> ext4"
    [[ "$DRY_RUN" == "true" ]] && log "[DRY] Would run: wipefs -a $TARGET_DEV && echo 'type=83' | sfdisk $TARGET_DEV && mkfs.ext4 -F -L agent_data $PARTITION" && true
    if [[ "$DRY_RUN" != "true" ]]; then
        wipefs -a "$TARGET_DEV" >/dev/null 2>&1 || true
        echo "type=83" | sfdisk "$TARGET_DEV" >/dev/null 2>&1
        udevadm settle
        mkfs.ext4 -F -L agent_data "$PARTITION" >/dev/null 2>&1
        mkdir -p "$DATA_MOUNT"
        # Idempotent fstab append
        if ! grep -q "$PARTITION" /etc/fstab; then
            echo "$PARTITION $DATA_MOUNT ext4 defaults,noatime,discard 0 2" >> /etc/fstab
        fi
        mount "$DATA_MOUNT"
        log "Mounted $PARTITION at $DATA_MOUNT"
    fi
fi

# === 4. SWAP SETUP ===
SWAP_FILE="$DATA_MOUNT/swapfile"
if swapon --show | grep -q "$SWAP_FILE" 2>/dev/null; then
    log "Swap file already active. Skipping."
else
    log "Creating ${SWAP_SIZE_GB}GB swap on $DATA_MOUNT..."
    [[ "$DRY_RUN" == "true" ]] && log "[DRY] Would create swapfile" && true
    if [[ "$DRY_RUN" != "true" ]]; then
        fallocate -l ${SWAP_SIZE_GB}G "$SWAP_FILE"
        chmod 600 "$SWAP_FILE"
        mkswap "$SWAP_FILE" >/dev/null 2>&1
        swapon "$SWAP_FILE"
        if ! grep -q "$SWAP_FILE" /etc/fstab; then
            echo "$SWAP_FILE none swap sw 0 0" >> /etc/fstab
        fi
        # Tune swappiness for AI workloads
        echo "vm.swappiness=10" > /etc/sysctl.d/99-ai-swap.conf
        sysctl -p /etc/sysctl.d/99-ai-swap.conf >/dev/null
        log "Swap enabled. Swappiness set to 10."
    fi
fi

# === 5. NETWORK SHARE (SAMBA) ===
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
   comment = Raspberry Pi 5 Agent Workspace
EOF
    log "Samba config appended. Set password: sudo smbpasswd -a $(logname || echo 'pi')"
    systemctl enable smbd nmbd >/dev/null 2>&1
    systemctl restart smbd nmbd
    log "Samba services enabled & restarted."
else
    log "Samba share already configured."
fi

# === 6. VALIDATION & NEXT STEPS ===
log "=== POST-SETUP VALIDATION ==="
df -h "$DATA_MOUNT" | tail -n +2
swapon --show
systemctl is-active smbd >/dev/null && log "✅ Samba: Active" || warn "❌ Samba: Inactive"
log "✅ Stage 1 completed. Reboot recommended before Stage 2."
log "Next: sudo reboot && cd /path/to/repo && bash scripts/stage2_core_stack.sh"
