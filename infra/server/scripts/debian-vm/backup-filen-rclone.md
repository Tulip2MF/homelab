# backup-filen-rclone.sh

Weekly rclone upload of all Harbour (TrueNAS) backup archives to Filen Cloud using client-side encryption. This is the off-site disaster recovery copy.

**Host:** Shipyard (Debian) `192.168.178.141`
**Install path:** `/usr/local/bin/backup-filen-rclone.sh`
**Cron:** `0 3 * * 0   /usr/local/bin/backup-filen-rclone.sh`
**Classification:** Executor

---

## Purpose

Reads PBS backup archives from the Harbour (TrueNAS) NFS mount and syncs them to Filen Cloud via rclone with the `filen-crypt` encrypted remote. The NVMe application data is not uploaded separately — it is already captured inside the Shipyard (Debian) PBS backup archive stored on Harbour (TrueNAS), so syncing Harbour (TrueNAS) is sufficient to cover everything.

On success, writes `/var/log/filen-last-success.txt` which is read by `monitor-backups.sh` to confirm cloud backup recency. If this marker is missing or older than 8 days, Tier-0 fails.

> ⚠️ **Missing improvement:** This script uses plain `rclone sync` without `--backup-dir`. If a PBS archive is deleted from Harbour (TrueNAS), it will be permanently deleted from Filen Cloud on the next run with no recovery path. Consider adding `--backup-dir "filen-crypt:backups-deleted/$(date +%F)"`. See `known-issues.md`.

---

## rclone Config Required

The following remotes must exist in `/root/.config/rclone/rclone.conf` on the Shipyard (Debian):

```ini
[filen]
type = webdav
url = https://webdav.filen.io
vendor = other
user = YOUR_FILEN_EMAIL
pass = YOUR_RCLONE_OBSCURED_PASSWORD

[filen-crypt]
type = crypt
remote = filen:homelab-backup
filename_encryption = standard
directory_name_encryption = true
password = YOUR_RCLONE_CRYPT_OBSCURED_PASSWORD
password2 = YOUR_RCLONE_CRYPT_OBSCURED_SALT
```

> 🔴 **Critical:** `rclone.conf` contains your Filen credentials AND the crypt passphrase. Loss of the passphrase makes your entire cloud backup permanently unreadable even if the files still exist. Back up `rclone.conf` to at least two independent offline locations before relying on this backup.

---

## Key Files

| File | Purpose |
|---|---|
| `/mnt/truenas` | Source — Harbour (TrueNAS) NFS mount (read-only) |
| `/root/.config/rclone/rclone.conf` | rclone credentials and crypt config — Tier-0 recovery material |
| `/var/log/filen-last-success.txt` | Success marker — read by `monitor-backups.sh` |
| `/var/log/filen-backup-YYYYMMDD.log` | Dated log per run — auto-rotated after 90 days |
| `/var/run/filen-backup.lock` | Lock file — prevents duplicate runs |
| `/var/run/backup_inhibit` | Checked at start; set on failure |

---

## Dependencies

- `rclone` installed: `apt install rclone`
- `filen-crypt` remote configured in `rclone.conf`
- Harbour (TrueNAS) NFS mounted at `/mnt/truenas`

---

## Install

```bash
cp backup-filen-rclone.sh /usr/local/bin/
chmod +x /usr/local/bin/backup-filen-rclone.sh
```

Add to crontab (`crontab -e`):
```
0 3 * * 0   /usr/local/bin/backup-filen-rclone.sh
```

Run manually on first setup to create the initial Filen marker:
```bash
/usr/local/bin/backup-filen-rclone.sh
cat /var/log/filen-last-success.txt
```

---

## Script

```bash
#!/usr/bin/env bash
#
# backup-filen-rclone.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Shipyard (Debian) (192.168.178.141)

set -euo pipefail

LOG="/var/log/filen-backup-$(date +%Y%m%d).log"
touch "$LOG"

# Acquire lock -- prevents duplicate runs if cron overlaps a long sync
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

# 4. NFS not hung
mountpoint -q "$NFS_MOUNT" \
    || fail "${NFS_MOUNT} is not mounted -- check NFS mount"
timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1 \
    || fail "Harbour (TrueNAS) NFS ${NFS_MOUNT} unresponsive -- cannot read PBS archives"

# 5. Sync Harbour (TrueNAS) --> Filen
echo "[FILEN-RCLONE] Syncing Harbour (TrueNAS) backup archives --> Filen..." | tee -a "$LOG"
rclone sync "$NFS_MOUNT" "$REMOTE_BACKUPS" \
    "${RCLONE_FLAGS[@]}" \
    || fail "rclone sync of Harbour (TrueNAS) archives failed"

# 6. Write success marker
DATE="$(date --iso-8601=seconds)"
echo "${DATE} rclone crypt backup to Filen completed successfully" > "$FILEN_MARKER" \
    || fail "Could not write success marker at ${FILEN_MARKER}"

echo "[FILEN-RCLONE] SUCCESS -- ${DATE}" | tee -a "$LOG"
exit 0
```
