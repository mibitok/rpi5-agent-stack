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

# === 2. STORAGE AUTO-DETECTION (FIXED) ===
log "Scanning block devices..."
ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's|/dev/||')

# Функция для конвертации размера в ГБ (примерно)
size_to_gb() {
    local size_str="$1"
    local num unit
    num=$(echo "$size_str" | grep -oE '^[0-9.]+')
    unit=$(echo "$size_str" | grep -oE '[KMGTP]i?B?$' | tr -d 'B')
    case "$unit" in
        K|ki) echo "$num / 1048576" | bc ;;
        M|Mi) echo "$num / 1024" | bc ;;
        G|Gi|'') printf "%.0f" "$num" ;;  # G или без единицы = уже в ГБ
        T|Ti) echo "$num * 1024" | bc ;;
        *) echo "0" ;;
    esac
}
export -f size_to_gb

# Получаем список дисков в формате: name size_in_gb
readarray -t DRIVES < <(lsblk -dnbo NAME,SIZE,RO,TYPE 2>/dev/null | while read -r name size ro type; do
    # Пропускаем: root-диск, read-only, не disk, размер < 10 ГБ
    [[ "$name" == "$ROOT_DEV" ]] && continue
    [[ "$type" != "disk" ]] && continue
    [[ "$ro" == "1" ]] && continue
    
    size_gb=$(size_to_gb "$size")
    [[ -z "$size_gb" || "$size_gb" -lt 10 ]] && continue
    
    echo "$name ${size_gb}G"
done)

if [[ ${#DRIVES[@]} -eq 0 ]]; then
    log "Available block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | tee -a "$LOG_FILE"
    die "No suitable external storage (>10GB, read-write, type=disk) found. Connect NVMe/SSD/USB."
fi

TARGET_DEV=$(echo "${DRIVES[0]}" | awk '{print $1}')
TARGET_SIZE=$(echo "${DRIVES[0]}" | awk '{print $2}')
log "Selected storage: $TARGET_DEV ($TARGET_SIZE)"
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
