# pbs-write-marker.sh

Writes a timestamped success marker to TrueNAS NFS after PBS completes its nightly backup run. The Debian VM reads this marker to confirm PBS ran within the RPO window.

**Host:** PBS Mini PC `192.168.178.142`
**Install path:** `/usr/local/bin/pbs-write-marker.sh`
**Cron:** `30 4 * * *   /usr/local/bin/pbs-write-marker.sh >> /var/log/pbs-marker.log 2>&1`
**Classification:** Executor

---

## Purpose

`monitor-backups.sh` on the Debian VM cannot directly query PBS to confirm a backup completed. Instead, this script runs on the PBS host after the backup window closes and writes a marker file to the shared TrueNAS NFS mount. The Debian VM reads that marker to verify backups ran within the last 25 hours.

This is the only script that runs on the PBS Mini PC. Everything else in the framework runs on Proxmox or the Debian VM.

---

## Marker File

Written to: `/mnt/truenas-backup/.pbs-last-success.txt`

This path resolves to the same TrueNAS dataset that the Debian VM mounts read-only at `/mnt/truenas`. The Debian VM reads the marker at `/mnt/truenas/.pbs-last-success.txt` — both paths point to the same file on TrueNAS.

---

## NFS Mount Architecture

The TrueNAS dataset (`/mnt/tank/backups/proxmox-backups`) is exported to two hosts with different permissions:

| Host | Mount path | Permission |
|---|---|---|
| PBS Mini PC `192.168.178.142` | `/mnt/truenas-backup` | Read-write (to write marker and PBS archives) |
| Debian VM `192.168.178.141` | `/mnt/truenas` | Read-only (for rclone uploads) |

---

## One-Time NFS Setup

**On TrueNAS** — configure NFS export for the backup dataset:
- Networks: `192.168.178.142/32` (read-write), `192.168.178.141/32` (read-only)
- Dataset: `/mnt/tank/backups/proxmox-backups`

**On PBS Mini PC** — add to `/etc/fstab`:
```
192.168.178.139:/mnt/tank/backups/proxmox-backups  /mnt/truenas-backup  nfs  rw,soft,timeo=30  0 0
```

Then mount:
```bash
mkdir -p /mnt/truenas-backup
mount /mnt/truenas-backup
# Verify writable
touch /mnt/truenas-backup/.write-test && rm /mnt/truenas-backup/.write-test
```

---

## Key Files

| File | Purpose |
|---|---|
| `/mnt/truenas-backup/.pbs-last-success.txt` | Marker file written here (on PBS NFS mount) |
| `/mnt/truenas/.pbs-last-success.txt` | Same file read from here (on Debian VM NFS mount) |
| `/var/run/backup_inhibit` | Checked at start — exits silently if set |
| `/var/log/pbs-marker.log` | Cron output log |

---

## Install

```bash
cp pbs-write-marker.sh /usr/local/bin/
chmod +x /usr/local/bin/pbs-write-marker.sh
```

Add to crontab on the PBS host (`crontab -e`):
```
30 4 * * *   /usr/local/bin/pbs-write-marker.sh >> /var/log/pbs-marker.log 2>&1
```

The cron time (04:30) must be after the PBS backup window closes. Adjust if your PBS jobs run late.

---

## Script

```bash
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
```
