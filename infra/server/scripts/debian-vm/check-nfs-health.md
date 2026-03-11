# check-nfs-health.sh

Standalone NFS health check. Verifies the Harbour (TrueNAS) NFS mount is alive, not hung in a D-state, and sourced from the expected host. Sets the inhibit and sends an alert on failure.

**Host:** Shipyard (Debian) `192.168.178.141`
**Install path:** `/usr/local/bin/check-nfs-health.sh`
**Cron:** `15 * * * *   /usr/local/bin/check-nfs-health.sh >> /var/log/nfs-health.log 2>&1`
**Classification:** Executor

---

## Purpose

`monitor-backups.sh` already checks NFS inline as part of the Tier-0 evaluation. This script exists as an independent hourly check that can be run standalone — for example, after a network event, a Harbour (TrueNAS) restart, or any time you want to confirm the mount is healthy without triggering a full Tier-0 evaluation.

---

## What It Checks

1. Mount point `/mnt/truenas` exists as a directory
2. Something is actually mounted there (not just an empty directory)
3. The mount responds within 10 seconds (detects D-state hung NFS mounts)
4. Harbour (TrueNAS) host `192.168.178.139` is reachable at network level via ping
5. The mount source matches the expected Harbour (TrueNAS) IP (not a wrong server)

---

## Key Files

| File | Purpose |
|---|---|
| `/mnt/truenas` | NFS mount point — read-only, sourced from Harbour (TrueNAS) |
| `/var/run/backup_inhibit` | Set on failure |
| `/var/log/nfs-health.log` | Cron output log |

---

## Dependencies

- Harbour (TrueNAS) NFS export configured for `192.168.178.141/32` (read-only)
- `/etc/fstab` entry for the NFS mount
- `findmnt` available (part of `util-linux`, installed by default on Debian)

---

## Install

```bash
cp check-nfs-health.sh /usr/local/bin/
chmod +x /usr/local/bin/check-nfs-health.sh
```

Add to crontab (`crontab -e`):
```
15 * * * *   /usr/local/bin/check-nfs-health.sh >> /var/log/nfs-health.log 2>&1
```

---

## Script

```bash
#!/usr/bin/env bash
#
# check-nfs-health.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Shipyard (Debian) (192.168.178.141)

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
    || fail "${NFS_MOUNT} is not mounted -- check /etc/fstab and Harbour (TrueNAS) NFS export"

# 3. Mount is responsive (not in D-state / hung)
if ! timeout "$NFS_TIMEOUT" ls "$NFS_MOUNT" >/dev/null 2>&1; then
    fail "${NFS_MOUNT} is unresponsive after ${NFS_TIMEOUT}s -- NFS may be hung (D-state)"
fi

# 4. Harbour (TrueNAS) host is reachable at network level
if ! ping -c 1 -W 3 "$TRUENAS_IP" >/dev/null 2>&1; then
    fail "Harbour (TrueNAS) host ${TRUENAS_IP} is not reachable via ping"
fi

# 5. Mount source matches expected Harbour (TrueNAS) IP
MOUNT_SOURCE=$(findmnt -n -o SOURCE "$NFS_MOUNT" 2>/dev/null || true)
if [ -n "$MOUNT_SOURCE" ] && ! echo "$MOUNT_SOURCE" | grep -q "$TRUENAS_IP"; then
    fail "NFS mount source is '${MOUNT_SOURCE}', expected ${TRUENAS_IP} -- wrong server?"
fi

echo "[NFS-HEALTH] PASS -- ${NFS_MOUNT} is mounted, responsive, source=${MOUNT_SOURCE}"
exit 0
```
