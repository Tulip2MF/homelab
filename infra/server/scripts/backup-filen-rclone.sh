#!/usr/bin/env bash
#
# backup-filen-rclone.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on:  Debian VM (192.168.178.141)
# rclone installed on Debian VM ONLY -- not TrueNAS, not Proxmox host.
#
# ARCHITECTURE:
#   All VMs + Proxmox --> PBS (192.168.178.142) --> TrueNAS (192.168.178.139)
#                                                   |
#              Debian VM mounts TrueNAS via NFS (/mnt/truenas)
#              rclone reads PBS archives from that mount
#              rclone crypt --> Filen Cloud
#
# NVMe app data (/var/lib/docker) is NOT uploaded separately.
# It is captured inside the Debian VM PBS backup archive on TrueNAS.
# Uploading TrueNAS is sufficient to cover everything.
#
# SETUP -- rclone.conf on Debian VM (~/.config/rclone/rclone.conf):
#
#   [filen]
#   type = webdav
#   url = https://webdav.filen.io
#   vendor = other
#   user = YOUR_FILEN_EMAIL
#   pass = YOUR_RCLONE_OBSCURED_PASSWORD      # rclone obscure <password>
#
#   [filen-crypt]
#   type = crypt
#   remote = filen:homelab-backup
#   filename_encryption = standard
#   directory_name_encryption = true
#   password = YOUR_RCLONE_CRYPT_OBSCURED_PASSWORD
#   password2 = YOUR_RCLONE_CRYPT_OBSCURED_SALT
#
# TIER-0 SECRETS: rclone.conf holds Filen credentials AND crypt passphrase.
#   Back up in at least TWO independent off-system locations (e.g. encrypted
#   file on USB + printed copy in safe). Loss of passphrase = data permanently
#   unreadable even if you have the Filen account.
#
# Cron (Debian VM -- weekly, after PBS window closes):
#   0 3 * * 0   /usr/local/bin/backup-filen-rclone.sh

set -euo pipefail

LOG="/var/log/filen-backup-$(date +%Y%m%d).log"
touch "$LOG"

# Acquire lock -- prevents duplicate runs if cron overlaps a long sync
# lock is released automatically when the script exits (fd 9 closed by kernel)
exec 9>/var/run/filen-backup.lock
flock -n 9 || {
    echo "[FILEN-RCLONE] Another instance already running -- exiting" >> "$LOG"
    exit 0
}

INHIBIT="/var/run/backup_inhibit"
[ -f "$INHIBIT" ] && exit 0

NFS_MOUNT="/mnt/truenas"
RCLONE_REMOTE="filen-crypt"
REMOTE_BACKUPS="${RCLONE_REMOTE}:backups"
FILEN_MARKER="/var/log/filen-last-success.txt"

# Rotate logs older than 90 days
find /var/log -maxdepth 1 -name "filen-backup-*.log" -mtime +90 -delete 2>/dev/null || true

RCLONE_FLAGS=(
    --transfers 8
    --checkers 16
    --fast-list
    --retries 3
    --low-level-retries 5
    --stats 60s
    --stats-one-line
    --log-level INFO
    --log-file "$LOG"
    --config /root/.config/rclone/rclone.conf
    --exclude ".zfs/**"
    --exclude "lost+found/**"
)

fail() {
    echo "[FILEN-RCLONE] FAIL: $1" | tee -a "$LOG" >&2
    touch "$INHIBIT"
    echo "Filen backup FAILED: $1" \
        | mail -s "[HOMELAB FILEN FAIL] $1" root 2>/dev/null || true
    exit 1
}

echo "[FILEN-RCLONE] Starting $(date --iso-8601=seconds)" | tee -a "$LOG"

# 1. Inhibit re-check
[ -f "$INHIBIT" ] && fail "backup_inhibit present -- aborting"

# 2. rclone available
command -v rclone >/dev/null 2>&1 || fail "rclone not installed -- apt install rclone"

# 3. crypt remote configured
rclone listremotes --config /root/.config/rclone/rclone.conf 2>/dev/null \
    | grep -q "^${RCLONE_REMOTE}:" \
    || fail "rclone remote '${RCLONE_REMOTE}' not in rclone.conf -- check setup"

# 4. NFS not hung (catches D-state mounts)
mountpoint -q "$NFS_MOUNT" \
    || fail "${NFS_MOUNT} is not mounted -- check NFS mount"
timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1 \
    || fail "TrueNAS NFS ${NFS_MOUNT} unresponsive -- cannot read PBS archives"

# 5. Sync TrueNAS --> Filen
# Source: all PBS backup archives for every VM + Proxmox, log files,
# and large personal files stored directly on TrueNAS.
echo "[FILEN-RCLONE] Syncing TrueNAS backup archives --> Filen..." | tee -a "$LOG"
rclone sync "$NFS_MOUNT" "$REMOTE_BACKUPS" \
    "${RCLONE_FLAGS[@]}" \
    || fail "rclone sync of TrueNAS archives failed"

# 6. Write success marker (read by monitor-backups.sh check 7)
DATE="$(date --iso-8601=seconds)"
echo "${DATE} rclone crypt backup to Filen completed successfully" > "$FILEN_MARKER" \
    || fail "Could not write success marker at ${FILEN_MARKER}"

echo "[FILEN-RCLONE] SUCCESS -- ${DATE}" | tee -a "$LOG"
exit 0
