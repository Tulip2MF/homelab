# monitor-backups.sh

Tier-0 evaluator. The single source of truth for whether the system is in a safe state. Runs every 5 minutes and either clears the inhibit (all checks passed) or sets it (any check failed). All backup and restore automation defers to this file.

**Host:** Shipyard (Debian) `192.168.178.141`
**Install path:** `/usr/local/bin/monitor-backups.sh`
**Cron:** `*/5 * * * *   /usr/local/bin/monitor-backups.sh >> /var/log/tier0.log 2>&1`
**Classification:** Evaluator

---

## Purpose

Implements the Tier-0 authority contract from Homelab-AB Section 2. On every run it evaluates six authority conditions in sequence. If all pass, `/var/run/backup_inhibit` is removed and `/var/run/tier0_heartbeat` is written. If any condition fails, `/var/run/backup_inhibit` is created and a failure email is sent immediately.

The heartbeat file is the external signal that the system is healthy. Absence of a fresh heartbeat is itself treated as a failure — silence is never interpreted as success.

---

## What It Checks

1. **Heartbeat staleness** — confirms the cron loop itself is alive
2. **UPS power** — non-blocking until NUT is configured (see Pending Items in deployment guide)
3. **NTP source** — clock must be syncing from Proxmox `192.168.178.127`, not any external server
4. **NVMe partition** — `/var/lib/docker` must be mounted and under capacity thresholds
5. **Harbour (TrueNAS)** — NFS responsive, ZFS pool ONLINE, capacity within limits
6. **PBS backup recency** — marker file on Harbour (TrueNAS) must be within 25-hour RPO window
7. **Filen cloud recency** — upload marker must be within 8-day window (weekly run + margin)

---

## Capacity Thresholds

| Level | Threshold | Effect |
|---|---|---|
| OK | < 70% | Passes |
| DEGRADED | ≥ 70% | Tier-0 FAILED |
| WARNING | ≥ 75% | Tier-0 FAILED |
| CRITICAL | ≥ 85% | Tier-0 FAILED |

Applies to both Harbour (TrueNAS) NFS and NVMe partition.

---

## Key Files

| File | Purpose |
|---|---|
| `/var/run/backup_inhibit` | Set = Tier-0 FAILED. Cleared only when all checks pass. |
| `/var/run/tier0_heartbeat` | Timestamp of last successful verification |
| `/mnt/truenas/.pbs-last-success.txt` | Written by `pbs-write-marker.sh` on Drydock (PBS — Proxmox) |
| `/var/log/filen-last-success.txt` | Written by `backup-filen-rclone.sh` after upload |
| `/var/log/tier0.log` | Cron output log |

---

## Dependencies

- `chrony` installed and configured to sync from `192.168.178.127`
- SSH key at `/root/.ssh/id_ed25519_truenas` with access to `healthcheck@192.168.178.139`
- Harbour (TrueNAS) NFS mounted at `/mnt/truenas`
- NVMe partition mounted at `/var/lib/docker`
- `pbs-write-marker.sh` running on Drydock (PBS — Proxmox) and writing to Harbour (TrueNAS) NFS
- `backup-filen-rclone.sh` having run at least once to create the Filen marker

---

## One-Time Setup

```bash
# 1. Generate SSH key for Harbour (TrueNAS) healthcheck user
ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_truenas -N ""

# 2. Accept Harbour (TrueNAS) host key
ssh-keyscan 192.168.178.139 >> /root/.ssh/known_hosts

# 3. Add public key to Harbour (TrueNAS) healthcheck user (via Harbour (TrueNAS) web UI)
cat /root/.ssh/id_ed25519_truenas.pub

# 4. Test SSH connection
ssh -i /root/.ssh/id_ed25519_truenas healthcheck@192.168.178.139 "sudo zpool list -H -o health tank"
# Expected: ONLINE

# 5. Configure NTP in /etc/chrony.conf
# server 192.168.178.127 iburst prefer
# makestep 1.0 3
systemctl restart chronyd
chronyc sources   # confirm * next to 192.168.178.127
```

---

## Install

```bash
cp monitor-backups.sh /usr/local/bin/
chmod +x /usr/local/bin/monitor-backups.sh
```

Add to crontab (`crontab -e`):
```
*/5 * * * *   /usr/local/bin/monitor-backups.sh >> /var/log/tier0.log 2>&1
```

---

## Script

```bash
#!/usr/bin/env bash
#
# monitor-backups.sh
#
# Tier-0 Evaluator -- SINGLE SOURCE OF TRUTH
# Runs on: Shipyard (Debian)  (192.168.178.141)
#
# ROLE:        evaluation only
# AUTHORITY:   none -- derives from Section 2
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# NETWORK MAP:
#   Main Server — Proxmox      192.168.178.127  (NTP master, hypervisor)
#   Harbour (TrueNAS)        192.168.178.139  (backup store, NFS server)
#   Drydock (PBS — Proxmox)       192.168.178.142  (nightly VM backups -> Harbour (TrueNAS))
#   Shipyard (Debian)         192.168.178.141  (THIS HOST -- apps + rclone)
#
# ARCHITECTURE:
#   All VMs + Proxmox --> PBS (192.168.178.142) --> Harbour (TrueNAS) (192.168.178.139)
#                                                   |
#                           Shipyard (Debian) mounts Harbour (TrueNAS) via NFS (/mnt/truenas)
#                           rclone reads PBS archives --> Filen Cloud
#
#   Main Server — Proxmox (192.168.178.127) = NTP master. All VMs MUST sync from it only.
#
# TIER-0 BLOCKING CONDITIONS:
#   1. UPS not online
#   2. Clock not syncing FROM Proxmox NTP master, or drift/staleness exceeded
#   3. NVMe partition not mounted or at/near capacity
#   4. Harbour (TrueNAS) NFS unresponsive
#   5. Harbour (TrueNAS) ZFS pool not ONLINE
#   6. Harbour (TrueNAS) at/near capacity
#   7. PBS backup not completed within RPO window
#   8. rclone Filen upload not completed within window

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
HEARTBEAT_FILE="/var/run/tier0_heartbeat"

# Must be > cron interval + script execution time.
# At */5 cron: 5*60 + 100s margin = 400s
HEARTBEAT_MAX_AGE=400

MAX_CAPACITY_OK=70
WARN_CAPACITY=75
CRIT_CAPACITY=85

NVME_MOUNT="/var/lib/docker"

NFS_MOUNT="/mnt/truenas"
TRUENAS_HOST="192.168.178.139"
TRUENAS_SSH_USER="healthcheck"
TRUENAS_SSH_KEY="/root/.ssh/id_ed25519_truenas"

PROXMOX_NTP_IP="192.168.178.127"
MAX_DRIFT_SEC=5
MAX_STALE_SEC=900    # 15 min

# PBS marker written by pbs-write-marker.sh on Drydock (PBS — Proxmox) to Harbour (TrueNAS) NFS.
# Path MUST match NFS_MOUNT and pbs-write-marker.sh MARKER variable.
PBS_MARKER="${NFS_MOUNT}/.pbs-last-success.txt"
PBS_BACKUP_AGE_MAX=90000    # 25 hours

# Written by backup-filen-rclone.sh on this host after successful upload.
FILEN_MARKER="/var/log/filen-last-success.txt"
FILEN_MAX_AGE=691200    # 8 days (weekly run + margin)

# ─────────────────────────────────────────────────────────────────────────────

fail() {
    echo "[TIER-0] FAIL: $1" >&2
    touch "$INHIBIT"
    echo "Tier-0 FAILED: $1" | mail -s "[HOMELAB TIER-0 FAILED] $1" root 2>/dev/null || true
    exit 1
}

pass() {
    rm -f "$INHIBIT"
    touch "$HEARTBEAT_FILE"
    echo "[TIER-0] VERIFIED -- all authorities passed"
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
### 1. HEARTBEAT
# Confirms the monitoring cron loop is running.
# Skipped on first boot -- pass() will create the file.
if [ -f "$HEARTBEAT_FILE" ]; then
    HEARTBEAT_AGE=$(( $(date +%s) - $(stat -c %Y "$HEARTBEAT_FILE") ))
    if [ "$HEARTBEAT_AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
        fail "Heartbeat stale (${HEARTBEAT_AGE}s > ${HEARTBEAT_MAX_AGE}s) -- cron may be broken"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
### 2. POWER (UPS)
# ⚠ PENDING SETUP: UPS USB cable not yet connected to Main Server — Proxmox (192.168.178.127).
# NUT is installed on Proxmox but not configured -- no device detected yet.
#
# TO ACTIVATE:
#   1. Connect UPS USB cable to Main Server — Proxmox
#   2. Run: nut-scanner -U  (on Proxmox) to identify driver + port
#   3. Generate NUT config files (nut.conf, ups.conf, upsd.conf, upsd.users,
#      upsmon.conf) for Proxmox master and Shipyard (Debian) slave
#   4. Install nut-client on Shipyard (Debian), configure upsmon.conf pointing to
#      192.168.178.127
#   5. Replace this block with the blocking check below and set UPS_NAME
#      to whatever name nut-scanner reports
#
# BLOCKING CHECK (activate once NUT is running):
#   UPS_NAME="ups"   # replace with actual name from: upsc -l
#   command -v upsc >/dev/null 2>&1 || fail "upsc not found -- install nut-client"
#   UPS_STATUS=$(upsc ${UPS_NAME}@192.168.178.127 2>/dev/null | grep "^ups.status" | awk '{print $2}') || true
#   [ -z "$UPS_STATUS" ] && fail "UPS status unreadable -- NUT on Main Server — Proxmox (192.168.178.127) unreachable"
#   [ "$UPS_STATUS" != "OL" ] && fail "UPS not ONLINE (state=${UPS_STATUS})"
#
# CURRENT BEHAVIOR: warn + email but do NOT block Tier-0 (setup pending)
UPS_WARN_SENT="/var/run/ups_setup_pending_warned"
if ! command -v upsc >/dev/null 2>&1; then
    echo "[TIER-0] WARN: upsc not installed on this VM -- install nut-client" >&2
    echo "UPS check PENDING: upsc not installed on Shipyard (Debian)" \
        | mail -s "[HOMELAB UPS PENDING] Install nut-client on Shipyard (Debian)" root 2>/dev/null || true
elif ! upsc -l 2>/dev/null | grep -q .; then
    if [ ! -f "$UPS_WARN_SENT" ]; then
        echo "[TIER-0] WARN: UPS/NUT not configured on Main Server — Proxmox (192.168.178.127) -- pending USB connection" >&2
        echo "UPS check PENDING: Connect UPS USB to Proxmox and configure NUT" \
            | mail -s "[HOMELAB UPS PENDING] NUT not configured on 192.168.178.127" root 2>/dev/null || true
        touch "$UPS_WARN_SENT"
    fi
else
    echo "[TIER-0] WARN: NUT reachable but UPS_NAME not confirmed in this script -- activate blocking check" >&2
    rm -f "$UPS_WARN_SENT"
fi

# ─────────────────────────────────────────────────────────────────────────────
### 3. TIME -- must sync FROM Proxmox NTP master (192.168.178.127)
command -v chronyc >/dev/null 2>&1 || fail "chronyc not found -- install chrony"

OFFSET=$(chronyc tracking 2>/dev/null | grep "Last offset" \
    | awk '{gsub(/[+-]/,"",$3); print int($3)}') || true
[ -z "$OFFSET" ] && fail "Cannot read clock offset -- chrony not responding"
[ "$OFFSET" -gt "$MAX_DRIFT_SEC" ] && fail "Clock drift ${OFFSET}s exceeds ${MAX_DRIFT_SEC}s"

LAST_SYNC=$(chronyc tracking 2>/dev/null | grep "Last update time" \
    | awk '{print int($5)}') || true
[ -z "$LAST_SYNC" ] && fail "Cannot determine last NTP sync time"
[ "$LAST_SYNC" -gt "$MAX_STALE_SEC" ] && \
    fail "Time sync stale (${LAST_SYNC}s > ${MAX_STALE_SEC}s)"

NTP_SOURCE=$(chronyc sources 2>/dev/null | awk '/^\*/ {print $2}') || true
[ -z "$NTP_SOURCE" ] && fail "No active NTP source -- chrony not locked to any server"
[ "$NTP_SOURCE" != "$PROXMOX_NTP_IP" ] && \
    fail "NTP source is '${NTP_SOURCE}', expected Proxmox (${PROXMOX_NTP_IP}) -- not syncing from NTP master"

# ─────────────────────────────────────────────────────────────────────────────
### 4. NVMe PARTITION -- primary application data (/var/lib/docker)
mountpoint -q "$NVME_MOUNT" 2>/dev/null || \
    fail "NVMe partition ${NVME_MOUNT} not mounted -- Docker volumes unavailable"
NVME_USED=$(df -P "$NVME_MOUNT" 2>/dev/null \
    | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || true
[ -z "$NVME_USED" ] && fail "Cannot read NVMe partition capacity"
[ "$NVME_USED" -ge "$CRIT_CAPACITY" ] && fail "NVMe CRITICAL capacity (${NVME_USED}%)"
[ "$NVME_USED" -ge "$WARN_CAPACITY" ] && fail "NVMe WARNING capacity (${NVME_USED}%)"
[ "$NVME_USED" -ge "$MAX_CAPACITY_OK" ] && fail "NVMe DEGRADED capacity (${NVME_USED}%)"

# ─────────────────────────────────────────────────────────────────────────────
### 5. TRUENAS (192.168.178.139) -- backup store and rclone source

# 5a. NFS responsiveness
timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1 || \
    fail "Harbour (TrueNAS) NFS ${NFS_MOUNT} unresponsive -- rclone source unavailable"

# 5b. ZFS pool health via SSH to dedicated healthcheck user
POOL_STATE=$(ssh -i "$TRUENAS_SSH_KEY" \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    "${TRUENAS_SSH_USER}@${TRUENAS_HOST}" \
    "sudo zpool list -H -o health tank" 2>/dev/null) || true
[ -z "$POOL_STATE" ] && fail "Cannot reach Harbour (TrueNAS) via SSH (${TRUENAS_HOST}) -- pool state unknown"
[ "$POOL_STATE" != "ONLINE" ] && fail "Harbour (TrueNAS) ZFS pool is ${POOL_STATE} -- archives may be degraded"

# 5c. Harbour (TrueNAS) capacity
TRUENAS_USED=$(df -P "$NFS_MOUNT" 2>/dev/null \
    | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || true
[ -z "$TRUENAS_USED" ] && fail "Cannot read Harbour (TrueNAS) capacity via NFS"
[ "$TRUENAS_USED" -ge "$CRIT_CAPACITY" ] && \
    fail "Harbour (TrueNAS) CRITICAL capacity (${TRUENAS_USED}%) -- PBS writes likely failing"
[ "$TRUENAS_USED" -ge "$WARN_CAPACITY" ] && fail "Harbour (TrueNAS) WARNING capacity (${TRUENAS_USED}%)"
[ "$TRUENAS_USED" -ge "$MAX_CAPACITY_OK" ] && fail "Harbour (TrueNAS) DEGRADED capacity (${TRUENAS_USED}%)"

# ─────────────────────────────────────────────────────────────────────────────
### 6. PBS BACKUP RECENCY
[ ! -f "$PBS_MARKER" ] && \
    fail "PBS marker missing at ${PBS_MARKER} -- PBS (192.168.178.142) may not have run or NFS not mounted"
PBS_AGE=$(( $(date +%s) - $(stat -c %Y "$PBS_MARKER") ))
[ "$PBS_AGE" -gt "$PBS_BACKUP_AGE_MAX" ] && \
    fail "PBS backup stale (${PBS_AGE}s > ${PBS_BACKUP_AGE_MAX}s) -- last backup may have failed"

# ─────────────────────────────────────────────────────────────────────────────
### 7. FILEN CLOUD BACKUP RECENCY
[ ! -f "$FILEN_MARKER" ] && \
    fail "Filen marker missing at ${FILEN_MARKER} -- rclone upload may never have succeeded"
FILEN_AGE=$(( $(date +%s) - $(stat -c %Y "$FILEN_MARKER") ))
[ "$FILEN_AGE" -gt "$FILEN_MAX_AGE" ] && \
    fail "Filen backup stale (${FILEN_AGE}s > ${FILEN_MAX_AGE}s) -- rclone upload may have failed"

# ─────────────────────────────────────────────────────────────────────────────
### 8. INHIBIT SELF-CHECK
[ -f "$INHIBIT" ] && \
    fail "Inhibit still present after all checks -- operator must clear manually"

# ─────────────────────────────────────────────────────────────────────────────
### 9. SUCCESS
pass
```
