#!/usr/bin/env bash
#
# pbs-write-marker.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: PBS Mini PC (192.168.178.142)
#
# Writes a success marker to TrueNAS NFS after PBS completes its nightly
# backup run. monitor-backups.sh on the Debian VM (192.168.178.141) reads this
# marker to confirm PBS ran within the RPO window.
#
# MARKER PATH must match monitor-backups.sh PBS_MARKER:
#   ${NFS_MOUNT}/.pbs-last-success.txt
#
# NFS SETUP on TrueNAS (192.168.178.139):
#   Export your backup dataset writable to PBS Mini PC (192.168.178.142).
#   The Debian VM mounts the same dataset read-only for rclone.
#   Example TrueNAS NFS export:
#     Dataset:  /mnt/tank/backups/proxmox-backups
#     Networks: 192.168.178.142/32    (read-write)
#               192.168.178.141/32 (read-only)
#
# NFS SETUP on PBS Mini PC (192.168.178.142):
#   Add to /etc/fstab:
#     192.168.178.139:/mnt/tank/backups/proxmox-backups  /mnt/truenas-backup  nfs  rw,soft,timeo=30  0 0
#   Then: mkdir -p /mnt/truenas-backup && mount /mnt/truenas-backup
#
# Cron (PBS Mini PC -- runs after backup window closes at ~04:00):
#   30 4 * * *   /usr/local/bin/pbs-write-marker.sh >> /var/log/pbs-marker.log 2>&1

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
[ -f "$INHIBIT" ] && exit 0

NFS_MOUNT="/mnt/truenas-backup"
MARKER="${NFS_MOUNT}/.pbs-last-success.txt"

fail() {
    echo "[PBS-MARKER] FAIL: $1" >&2
    echo "PBS marker write FAILED: $1" \
        | mail -s "[HOMELAB PBS MARKER FAIL] $1" root 2>/dev/null || true
    exit 1
}

# 1. NFS mounted
mountpoint -q "$NFS_MOUNT" 2>/dev/null \
    || fail "NFS ${NFS_MOUNT} not mounted on PBS host (192.168.178.142)"

# 2. NFS writable
timeout 5 touch "${NFS_MOUNT}/.write-test-pbs" 2>/dev/null \
    || fail "NFS ${NFS_MOUNT} is not writable from PBS host"
rm -f "${NFS_MOUNT}/.write-test-pbs"

# 3. Write marker
DATE="$(date --iso-8601=seconds)"
echo "${DATE} PBS backup completed successfully" > "$MARKER" \
    || fail "Could not write marker to ${MARKER}"

echo "[PBS-MARKER] SUCCESS -- ${DATE}"
exit 0
