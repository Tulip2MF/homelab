# check-nvme-health.sh

Daily NVMe SMART health check and ZFS rpool status check on the Main Server — Proxmox. Monitors the Samsung 990 PRO drive for SMART warnings, wear level, and IO latency. Sets the inhibit and emails on failure.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/check-nvme-health.sh`
**Cron:** `0 6 * * *   /usr/local/bin/check-nvme-health.sh >> /var/log/nvme-health.log 2>&1`
**Classification:** Executor

---

## Purpose

The Samsung 990 PRO (2TB) at `/dev/nvme0` hosts the Proxmox ZFS rpool and the NVMe partition used for Docker container volumes on the Shipyard (Debian). This script runs daily on the Main Server — Proxmox and checks SMART health, wear level, and the container partition capacity.

Note: the 5 HDDs (3×4TB + 2×8TB) are passed through to Harbour (TrueNAS) via the LSI SAS 9300-16i HBA and are **not** visible from Proxmox. HDD SMART data must be checked directly in the Harbour (TrueNAS) web UI.

---

## What It Checks

1. **SMART critical warning** — `critical_warning` field must be `0`
2. **NVMe wear** — `percentage_used` checked against warn (70%) and critical (85%) thresholds
3. **Container partition capacity** — `/var/lib/docker` disk usage checked against thresholds
4. **ZFS rpool health** — Proxmox boot pool (`rpool`) must be `ONLINE`

---

## Failure vs Warning Behaviour

| Condition | Action |
|---|---|
| SMART critical warning | Sets inhibit, emails `[FAIL]` |
| Wear ≥ CRIT (85%) | Sets inhibit, emails `[FAIL]` — replace drive soon |
| Wear ≥ WARN (70%) | Emails `[WARN]` only — does **not** set inhibit |
| Container partition ≥ any threshold | Sets inhibit, emails `[FAIL]` |
| rpool not ONLINE | Sets inhibit, emails `[FAIL]` |

---

## Capacity Thresholds

| Level | Threshold |
|---|---|
| DEGRADED | ≥ 70% |
| WARNING | ≥ 75% |
| CRITICAL | ≥ 85% |

---

## Key Files

| File | Purpose |
|---|---|
| `/dev/nvme0` | Samsung 990 PRO device |
| `/var/lib/docker` | Docker container volumes partition |
| `/var/run/backup_inhibit` | Set on failure |
| `/var/log/nvme-health.log` | Cron output log — also read by `homelab-daily-report.sh` if forwarded |

---

## Dependencies

- `nvme-cli` installed: `apt install nvme-cli`
- `zpool` available (included in Proxmox)

---

## Install

```bash
cp check-nvme-health.sh /usr/local/bin/
chmod +x /usr/local/bin/check-nvme-health.sh
```

Add to crontab on Proxmox (`crontab -e`):
```
0 6 * * *   /usr/local/bin/check-nvme-health.sh >> /var/log/nvme-health.log 2>&1
```

---

## Script

```bash
#!/usr/bin/env bash
#
# check-nvme-health.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)
# Monitors Samsung 990 PRO NVMe (2TB) SMART health, wear, and container
# partition capacity. Also checks rpool ZFS health.

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
NVME_DEV="/dev/nvme0"
NVME_MOUNT="/var/lib/docker"

CRIT_CAPACITY=85
WARN_CAPACITY=75
MAX_CAPACITY_OK=70

# NVMe wear thresholds (percentage_used -- direct, no inversion)
# Samsung 990 PRO: rated 1200 TBW on 2TB model
NVME_WEAR_WARN=70    # 30% life remaining -- plan for replacement
NVME_WEAR_CRIT=85    # 15% life remaining -- replace soon

fail() {
    echo "[NVME-HEALTH] FAIL: $1" >&2
    touch "$INHIBIT"
    echo "NVMe health FAILED: $1" | mail -s "[HOMELAB NVME FAIL] $1" root 2>/dev/null || true
    exit 1
}

warn() {
    echo "[NVME-HEALTH] WARN: $1" >&2
    echo "NVMe health WARN: $1" | mail -s "[HOMELAB NVME WARN] $1" root 2>/dev/null || true
    # WARN does not set inhibit -- monitor and plan
}

command -v nvme >/dev/null 2>&1 || fail "nvme-cli not installed -- apt install nvme-cli"

# 1. SMART critical warning (0 = healthy)
SMART_STATUS=$(nvme smart-log "$NVME_DEV" 2>/dev/null \
    | grep "critical_warning" | awk '{print $3}') || true
[ -z "$SMART_STATUS" ] && fail "Cannot read SMART data from ${NVME_DEV}"
[ "$SMART_STATUS" != "0" ] && \
    fail "NVMe SMART critical_warning=${SMART_STATUS} -- drive needs attention"

# 2. Wear (percentage_used)
PCT_USED=$(nvme smart-log "$NVME_DEV" 2>/dev/null \
    | grep "percentage_used" | awk '{print int($3)}') || true
[ -z "$PCT_USED" ] && fail "Cannot read percentage_used from ${NVME_DEV}"
[ "$PCT_USED" -ge "$NVME_WEAR_CRIT" ] && \
    fail "NVMe wear CRITICAL: ${PCT_USED}% used (>= ${NVME_WEAR_CRIT}%) -- replace drive"
[ "$PCT_USED" -ge "$NVME_WEAR_WARN" ] && \
    warn "NVMe wear WARNING: ${PCT_USED}% used (>= ${NVME_WEAR_WARN}%) -- plan replacement"

# 3. Container partition capacity
if mountpoint -q "$NVME_MOUNT" 2>/dev/null; then
    USED=$(df -P "$NVME_MOUNT" | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}')
    [ "$USED" -ge "$CRIT_CAPACITY" ] && fail "Container partition CRITICAL (${USED}%)"
    [ "$USED" -ge "$WARN_CAPACITY" ] && fail "Container partition WARNING (${USED}%)"
    [ "$USED" -ge "$MAX_CAPACITY_OK" ] && fail "Container partition DEGRADED (${USED}%)"
else
    fail "/var/lib/docker not mounted -- NVMe may not be attached or fstab missing"
fi

# 4. Proxmox rpool ZFS health
RPOOL_STATE=$(zpool list -H -o health rpool 2>/dev/null) || true
[ -z "$RPOOL_STATE" ] && fail "Cannot read rpool health"
[ "$RPOOL_STATE" != "ONLINE" ] && fail "rpool is ${RPOOL_STATE} -- ZFS pool degraded"

echo "[NVME-HEALTH] PASS -- wear=${PCT_USED}%, container partition OK, rpool ONLINE"
exit 0
```
