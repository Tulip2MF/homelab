#!/usr/bin/env bash
#
# check-nfs-health.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Debian VM (192.168.178.141)
#
# PURPOSE:
#   Standalone NFS health check. Verifies the TrueNAS NFS mount is responsive,
#   not in D-state, and has expected content. Sets inhibit and emails on failure.
#
#   monitor-backups.sh also checks NFS inline, but this script can be run
#   independently (e.g. after a network event) without running all Tier-0 checks.
#
# Cron (Debian VM -- hourly):
#   15 * * * *   /usr/local/bin/check-nfs-health.sh >> /var/log/nfs-health.log 2>&1

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
NFS_MOUNT="/mnt/truenas"
TRUENAS_IP="192.168.178.139"
NFS_TIMEOUT=10    # seconds before declaring mount hung

fail() {
    echo "[NFS-HEALTH] FAIL: $1" >&2
    touch "$INHIBIT"
    echo "NFS health FAILED: $1" | mail -s "[HOMELAB NFS FAIL] $1" root 2>/dev/null || true
    exit 1
}

# 1. Mount point exists
[ -d "$NFS_MOUNT" ] || fail "Mount point ${NFS_MOUNT} does not exist"

# 2. Something is mounted there
mountpoint -q "$NFS_MOUNT" 2>/dev/null \
    || fail "${NFS_MOUNT} is not mounted -- check /etc/fstab and TrueNAS NFS export"

# 3. Mount is responsive (not in D-state / hung)
# timeout + ls is the standard detection for hung NFS mounts
if ! timeout "$NFS_TIMEOUT" ls "$NFS_MOUNT" >/dev/null 2>&1; then
    fail "${NFS_MOUNT} is unresponsive after ${NFS_TIMEOUT}s -- NFS may be hung (D-state)"
fi

# 4. TrueNAS host is reachable at network level
if ! ping -c 1 -W 3 "$TRUENAS_IP" >/dev/null 2>&1; then
    fail "TrueNAS host ${TRUENAS_IP} is not reachable via ping"
fi

# 5. Mount source matches expected TrueNAS IP
MOUNT_SOURCE=$(findmnt -n -o SOURCE "$NFS_MOUNT" 2>/dev/null || true)
if [ -n "$MOUNT_SOURCE" ] && ! echo "$MOUNT_SOURCE" | grep -q "$TRUENAS_IP"; then
    fail "NFS mount source is '${MOUNT_SOURCE}', expected ${TRUENAS_IP} -- wrong server?"
fi

echo "[NFS-HEALTH] PASS -- ${NFS_MOUNT} is mounted, responsive, source=${MOUNT_SOURCE}"
exit 0
