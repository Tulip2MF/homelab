# homelab-daily-report.sh

Sends a consolidated daily health email covering the full homelab backup and infrastructure chain. Read-only — never modifies system state, never sets the inhibit.

**Host:** Debian VM `192.168.178.141`
**Install path:** `/usr/local/bin/homelab-daily-report.sh`
**Cron:** `0 7 * * *   /usr/local/bin/homelab-daily-report.sh >> /var/log/homelab-daily.log 2>&1`
**Classification:** Executor (reporting only)

---

## Purpose

Provides a single daily snapshot of the entire system in one email. This complements — but does not replace — the reactive alerts sent immediately by other scripts when something breaks. Those scripts alert when something goes wrong. This script gives you confirmation every morning that everything is still healthy, along with a summary of capacity, recency, and container status.

This script reads existing state only. All enforcement and inhibit management is left to the scripts that own each check.

---

## Report Sections

| Section | What it shows |
|---|---|
| 1. Tier-0 Integrity | Inhibit state, heartbeat freshness |
| 2. Power (UPS) | NUT status, battery charge and runtime |
| 3. Time Sync | NTP source, offset, last sync age |
| 4. TrueNAS Storage | NFS mount, ZFS pool health, capacity |
| 5. Docker Runtime Storage | NVMe partition mount and capacity |
| 6. PBS Backup SLA | PBS marker age vs 25-hour RPO |
| 7. Filen Cloud SLA | Filen marker age vs 8-day RPO |
| 8. Database Dumps | Age and size of all pg and redis dumps |
| 9. Docker Container Status | Running containers, expected vs actual |
| 10. Disk Space Summary | df for all key mounts |
| 11. Recent Tier-0 Log | Last 20 lines of `/var/log/tier0.log` |
| 12. Recent Script Activity | Last run time and last log line per script |

---

## Email Subject Format

```
[HOMELAB DAILY] OK | 2026-03-11 | issues=0 warn=0
[HOMELAB DAILY] DEGRADED | 2026-03-11 | issues=0 warn=2
[HOMELAB DAILY] ACTION REQUIRED | 2026-03-11 | issues=3 warn=1
```

---

## Known Limitation

Section 12 (Recent Script Activity) looks for `/var/log/db-dumps.log` but `dump-databases.sh` writes dated logs (`db-dumps-YYYY-MM-DD.log`). This path will always show "log not found". Fix: change the lookup to `ls -t /var/log/db-dumps-*.log | head -1`. See `known-issues.md`.

The NVMe SMART section (Section 5) notes that `check-nvme-health.sh` runs on Proxmox, not this VM. The log is not automatically forwarded, so SMART data will not appear in the daily report unless you add a forwarding mechanism (rsync or remote syslog from Proxmox).

---

## Key Files

| File | Purpose |
|---|---|
| `/var/log/homelab-daily-YYYY-MM-DD.log` | Full report written here, then emailed |
| `/var/run/backup_inhibit` | Read to determine Tier-0 state |
| `/var/run/tier0_heartbeat` | Read to confirm monitor-backups.sh cron is alive |
| `/mnt/truenas/.pbs-last-success.txt` | PBS marker — read for RPO check |
| `/var/log/filen-last-success.txt` | Filen marker — read for RPO check |
| `/mnt/truenas/db-dumps/` | Scanned for dump files |

---

## Dependencies

- `chrony` for NTP section
- `docker` for container status section
- SSH key at `/root/.ssh/id_ed25519_truenas` for ZFS pool detail query
- TrueNAS NFS mounted at `/mnt/truenas`
- Outbound mail configured via msmtp

---

## Install

```bash
cp homelab-daily-report.sh /usr/local/bin/
chmod +x /usr/local/bin/homelab-daily-report.sh
```

Add to crontab (`crontab -e`):
```
0 7 * * *   /usr/local/bin/homelab-daily-report.sh >> /var/log/homelab-daily.log 2>&1
```

Run manually to test:
```bash
/usr/local/bin/homelab-daily-report.sh
# Check inbox for [HOMELAB DAILY] email
```

---

## Script

```bash
#!/usr/bin/env bash
#
# homelab-daily-report.sh
#
# ROLE:        reporting only
# AUTHORITY:   none
# FAIL MODE:   open (report always sends, even if sections fail)
# AUTO-REPAIR: forbidden
# READ-ONLY:   never sets inhibit, never restarts services, never modifies state
#
# Runs on: Debian VM (192.168.178.141, hostname: shipyard)

set -euo pipefail
export LC_ALL=C

DATE=$(date +%F)
NOW=$(date +%s)
REPORT="/var/log/homelab-daily-${DATE}.log"

INHIBIT="/var/run/backup_inhibit"
HEARTBEAT_FILE="/var/run/tier0_heartbeat"
HEARTBEAT_MAX_AGE=400

NFS_MOUNT="/mnt/truenas"
TRUENAS_HOST="192.168.178.139"
TRUENAS_SSH_USER="healthcheck"
TRUENAS_SSH_KEY="/root/.ssh/id_ed25519_truenas"
PROXMOX_NTP_IP="192.168.178.127"

PBS_MARKER="${NFS_MOUNT}/.pbs-last-success.txt"
FILEN_MARKER="/var/log/filen-last-success.txt"
DUMP_DIR="${NFS_MOUNT}/db-dumps"
NVME_MOUNT="/var/lib/docker"

PBS_RPO_MAX=90000
FILEN_RPO_MAX=691200
DB_RPO_MAX=93600

MAX_CAPACITY_OK=70
WARN_CAPACITY=75
CRIT_CAPACITY=85

NVME_HEALTH_LOG="/var/log/nvme-health.log"

ISSUES=0
WARNINGS=0
OVERALL="OK"

section() {
    echo ""
    echo "-------------------------------------------------------------------"
    printf "  %s\n" "$1"
    echo "-------------------------------------------------------------------"
}

fmt_age() {
    local S="$1"
    if   [ "$S" -lt 60 ];    then echo "${S}s"
    elif [ "$S" -lt 3600 ];  then echo "$(( S/60 ))m"
    elif [ "$S" -lt 86400 ]; then echo "$(( S/3600 ))h $(( (S%3600)/60 ))m"
    else                          echo "$(( S/86400 ))d $(( (S%86400)/3600 ))h"
    fi
}

cap_label() {
    local PCT="$1"
    if   [ "$PCT" -ge "$CRIT_CAPACITY" ];    then echo "${PCT}%  [CRITICAL >= ${CRIT_CAPACITY}%]";    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    elif [ "$PCT" -ge "$WARN_CAPACITY" ];    then echo "${PCT}%  [WARNING >= ${WARN_CAPACITY}%]";     WARNINGS=$(( WARNINGS+1 ))
    elif [ "$PCT" -ge "$MAX_CAPACITY_OK" ];  then echo "${PCT}%  [DEGRADED >= ${MAX_CAPACITY_OK}%]";  WARNINGS=$(( WARNINGS+1 ))
    else                                          echo "${PCT}%  [OK]"
    fi
}

check_marker() {
    local FILE="$1" RPO="$2" LABEL="$3"
    if [ ! -f "$FILE" ]; then
        printf "  %-28s MISSING  (marker file not found)\n" "${LABEL}:"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        return
    fi
    local TS AGE
    if ! TS=$(timeout 5 stat -c %Y "$FILE" 2>/dev/null); then
        printf "  %-28s STAT FAILED\n" "${LABEL}:"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        return
    fi
    AGE=$(( NOW - TS ))
    local AGE_HUMAN LAST_DATE
    AGE_HUMAN=$(fmt_age "$AGE")
    LAST_DATE=$(date -d "@${TS}" "+%F %T" 2>/dev/null || echo "unknown")
    if [ "$AGE" -lt "$RPO" ]; then
        printf "  %-28s OK       age=%s  last=%s\n" "${LABEL}:" "$AGE_HUMAN" "$LAST_DATE"
    else
        printf "  %-28s STALE    age=%s  last=%s  (RPO=%s)\n" \
            "${LABEL}:" "$AGE_HUMAN" "$LAST_DATE" "$(fmt_age "$RPO")"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    fi
}

mkdir -p /var/log

{

echo "==================================================================="
echo "  HOMELAB DAILY HEALTH REPORT"
printf "  Host : %s (192.168.178.141)\n" "$(hostname)"
echo "  Date : ${DATE}  $(date +%T)"
echo "==================================================================="

section "1. TIER-0 INTEGRITY"

if [ -f "$INHIBIT" ]; then
    INHIBIT_CONTENT=$(cat "$INHIBIT" 2>/dev/null || echo "(unreadable)")
    echo "  STATUS:   FAILED  -- backup_inhibit is SET"
    echo "  Reason:   ${INHIBIT_CONTENT}"
    echo "  Action:   Investigate cause. Clear manually only after root cause resolved:"
    echo "            rm /var/run/backup_inhibit"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    echo "  STATUS:   VERIFIED  -- backup_inhibit not set"
fi

if [ -f "$HEARTBEAT_FILE" ]; then
    HB_AGE=$(( NOW - $(stat -c %Y "$HEARTBEAT_FILE") ))
    HB_AGE_HUMAN=$(fmt_age "$HB_AGE")
    HB_LAST=$(date -d "@$(stat -c %Y "$HEARTBEAT_FILE")" "+%F %T" 2>/dev/null || echo "unknown")
    if [ "$HB_AGE" -gt "$HEARTBEAT_MAX_AGE" ]; then
        echo "  Heartbeat: STALE   age=${HB_AGE_HUMAN}  last=${HB_LAST}  (max=$(fmt_age "$HEARTBEAT_MAX_AGE"))"
        echo "             monitor-backups.sh cron may be broken"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    else
        echo "  Heartbeat: OK      age=${HB_AGE_HUMAN}  last=${HB_LAST}"
    fi
else
    echo "  Heartbeat: MISSING -- monitor-backups.sh has not yet written a heartbeat"
    WARNINGS=$(( WARNINGS+1 ))
fi

section "2. POWER (UPS)"

if ! command -v upsc >/dev/null 2>&1; then
    echo "  STATUS:   PENDING  -- upsc not installed (apt install nut-client)"
    WARNINGS=$(( WARNINGS+1 ))
elif ! upsc -l 2>/dev/null | grep -q .; then
    echo "  STATUS:   PENDING  -- NUT not reachable or no UPS configured on Proxmox"
    WARNINGS=$(( WARNINGS+1 ))
else
    UPS_NAME=$(upsc -l 2>/dev/null | head -1 || echo "")
    if [ -n "$UPS_NAME" ]; then
        UPS_STATUS=$(upsc "${UPS_NAME}@${PROXMOX_NTP_IP}" 2>/dev/null \
            | grep "^ups.status" | awk '{print $3}' || echo "UNKNOWN")
        UPS_CHARGE=$(upsc "${UPS_NAME}@${PROXMOX_NTP_IP}" 2>/dev/null \
            | grep "^battery.charge" | awk '{print $3}' || echo "?")
        UPS_RUNTIME=$(upsc "${UPS_NAME}@${PROXMOX_NTP_IP}" 2>/dev/null \
            | grep "^battery.runtime" | awk '{print $3}' || echo "?")
        UPS_LOAD=$(upsc "${UPS_NAME}@${PROXMOX_NTP_IP}" 2>/dev/null \
            | grep "^ups.load" | awk '{print $3}' || echo "?")
        if [ "$UPS_STATUS" = "OL" ]; then
            echo "  STATUS:   ONLINE   (OL)"
        elif [ "$UPS_STATUS" = "OL CHRG" ]; then
            echo "  STATUS:   ONLINE + CHARGING"
        else
            echo "  STATUS:   ${UPS_STATUS}  [ATTENTION REQUIRED]"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        fi
        echo "  Battery:  charge=${UPS_CHARGE}%  runtime=${UPS_RUNTIME}s  load=${UPS_LOAD}%"
    fi
fi

section "3. TIME SYNC (NTP)"

if ! command -v chronyc >/dev/null 2>&1; then
    echo "  STATUS:   ERROR  -- chronyc not found"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    NTP_SOURCE=$(chronyc sources 2>/dev/null | awk '/^\*/ {print $2}' || echo "")
    OFFSET_RAW=$(chronyc tracking 2>/dev/null | grep "Last offset" | awk '{print $4}' || echo "0")
    OFFSET_ABS=$(echo "$OFFSET_RAW" | awk '{v=$1; if(v<0)v=-v; printf "%.3f", v}' 2>/dev/null || echo "?")
    LAST_SYNC=$(chronyc tracking 2>/dev/null | grep "Last update time" | awk '{print int($5)}' || echo "0")

    if [ -z "$NTP_SOURCE" ]; then
        echo "  STATUS:   FAILED  -- no active NTP source"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    elif [ "$NTP_SOURCE" != "$PROXMOX_NTP_IP" ]; then
        echo "  STATUS:   WRONG SOURCE -- ${NTP_SOURCE} (expected: ${PROXMOX_NTP_IP})"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    else
        echo "  STATUS:   OK  -- syncing from Proxmox NTP master (${PROXMOX_NTP_IP})"
    fi
    echo "  Offset:   ${OFFSET_ABS}s   Last sync: $(fmt_age "$LAST_SYNC") ago"
fi

section "4. TRUENAS STORAGE (192.168.178.139)"

NFS_OK=0
if ! timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    echo "  NFS mount:    UNRESPONSIVE  (${NFS_MOUNT})"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    MOUNT_SOURCE=$(findmnt -n -o SOURCE "$NFS_MOUNT" 2>/dev/null || echo "unknown")
    echo "  NFS mount:    OK            ${NFS_MOUNT}  source=${MOUNT_SOURCE}"
    NFS_OK=1
fi

POOL_STATE=$(ssh -i "$TRUENAS_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
    -o StrictHostKeyChecking=yes "${TRUENAS_SSH_USER}@${TRUENAS_HOST}" \
    "sudo zpool list -H -o health tank" 2>/dev/null) || POOL_STATE=""

if [ -z "$POOL_STATE" ]; then
    echo "  ZFS pool:     UNKNOWN -- cannot reach TrueNAS via SSH"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
elif [ "$POOL_STATE" != "ONLINE" ]; then
    echo "  ZFS pool:     ${POOL_STATE}  [DEGRADED]"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    POOL_DETAIL=$(ssh -i "$TRUENAS_SSH_KEY" -o ConnectTimeout=10 -o BatchMode=yes \
        -o StrictHostKeyChecking=yes "${TRUENAS_SSH_USER}@${TRUENAS_HOST}" \
        "sudo zpool list -H -o name,size,alloc,free,capacity,health tank" 2>/dev/null) || POOL_DETAIL=""
    echo "  ZFS pool:     ONLINE"
    [ -n "$POOL_DETAIL" ] && echo "  Pool detail:  ${POOL_DETAIL}"
fi

if [ "$NFS_OK" -eq 1 ]; then
    TRUENAS_PCT=$(df -P "$NFS_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || TRUENAS_PCT=""
    TRUENAS_DF=$(df -h "$NFS_MOUNT" 2>/dev/null | awk 'NR==2 {print "used="$3"  avail="$4"  total="$2}') || TRUENAS_DF=""
    if [ -n "$TRUENAS_PCT" ]; then
        printf "  Capacity:     %s\n" "$(cap_label "$TRUENAS_PCT")"
        [ -n "$TRUENAS_DF" ] && echo "                ${TRUENAS_DF}"
    fi
fi

section "5. DOCKER RUNTIME STORAGE (NVMe /var/lib/docker)"

if ! mountpoint -q "$NVME_MOUNT" 2>/dev/null; then
    echo "  Mount:        NOT MOUNTED  (${NVME_MOUNT})"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    NVME_PCT=$(df -P "$NVME_MOUNT" 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || NVME_PCT=0
    NVME_DF=$(df -h "$NVME_MOUNT" 2>/dev/null | awk 'NR==2 {print "used="$3"  avail="$4"  total="$2}') || NVME_DF=""
    printf "  Capacity:     %s\n" "$(cap_label "$NVME_PCT")"
    [ -n "$NVME_DF" ] && echo "                ${NVME_DF}"
fi

if [ -f "$NVME_HEALTH_LOG" ]; then
    NVME_LAST=$(tail -1 "$NVME_HEALTH_LOG" 2>/dev/null || echo "")
    [ -n "$NVME_LAST" ] && echo "  SMART log:    ${NVME_LAST}"
else
    echo "  SMART/rpool:  check-nvme-health.sh runs on Proxmox (192.168.178.127)"
    echo "                Log: /var/log/nvme-health.log on that host"
fi

section "6. PBS BACKUP SLA"
check_marker "$PBS_MARKER" "$PBS_RPO_MAX" "PBS last backup"
if [ -f "$PBS_MARKER" ]; then
    PBS_CONTENT=$(timeout 5 cat "$PBS_MARKER" 2>/dev/null | head -1 || echo "")
    [ -n "$PBS_CONTENT" ] && echo "  Marker text:  ${PBS_CONTENT}"
fi

section "7. FILEN CLOUD BACKUP SLA"
check_marker "$FILEN_MARKER" "$FILEN_RPO_MAX" "Filen last upload"
if [ -f "$FILEN_MARKER" ]; then
    FILEN_CONTENT=$(cat "$FILEN_MARKER" 2>/dev/null | head -1 || echo "")
    [ -n "$FILEN_CONTENT" ] && echo "  Marker text:  ${FILEN_CONTENT}"
fi

section "8. DATABASE DUMPS"

if ! timeout 5 ls "$DUMP_DIR" >/dev/null 2>&1; then
    echo "  Dump directory: UNAVAILABLE  (${DUMP_DIR})"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    for LABEL in paperless immich; do
        NEWEST=$(ls -t "${DUMP_DIR}/pg-${LABEL}-"*.dump 2>/dev/null | head -1 || echo "")
        if [ -z "$NEWEST" ]; then
            printf "  %-10s pg dump:   MISSING\n" "${LABEL}"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        else
            TS=$(timeout 5 stat -c %Y "$NEWEST" 2>/dev/null || echo 0)
            AGE=$(( NOW - TS ))
            SZ=$(du -sh "$NEWEST" 2>/dev/null | cut -f1 || echo "?")
            if [ "$AGE" -lt "$DB_RPO_MAX" ]; then
                printf "  %-10s pg dump:   OK       age=%-8s  size=%s\n" "$LABEL" "$(fmt_age "$AGE")" "$SZ"
            else
                printf "  %-10s pg dump:   STALE    age=%-8s  size=%s\n" "$LABEL" "$(fmt_age "$AGE")" "$SZ"
                ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
            fi
        fi
    done

    for LABEL in paperless; do
        NEWEST=$(ls -t "${DUMP_DIR}/redis-${LABEL}-"*.rdb 2>/dev/null | head -1 || echo "")
        if [ -z "$NEWEST" ]; then
            printf "  %-10s redis rdb: MISSING\n" "$LABEL"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        else
            TS=$(timeout 5 stat -c %Y "$NEWEST" 2>/dev/null || echo 0)
            AGE=$(( NOW - TS ))
            SZ=$(du -sh "$NEWEST" 2>/dev/null | cut -f1 || echo "?")
            if [ "$AGE" -lt "$DB_RPO_MAX" ]; then
                printf "  %-10s redis rdb: OK       age=%-8s  size=%s\n" "$LABEL" "$(fmt_age "$AGE")" "$SZ"
            else
                printf "  %-10s redis rdb: STALE    age=%-8s  size=%s\n" "$LABEL" "$(fmt_age "$AGE")" "$SZ"
                ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
            fi
        fi
    done
    echo "  (immich redis: ephemeral cache -- no dump by design)"
fi

section "9. DOCKER CONTAINER STATUS"

if command -v docker >/dev/null 2>&1; then
    EXPECTED=(paperless-db-1 paperless-broker-1 immich_postgres immich_redis)
    RUNNING=$(docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "")
    echo "  Running containers:"
    echo "$RUNNING" | while IFS=$'\t' read -r NAME STATUS IMAGE; do
        printf "    %-28s %-20s  %s\n" "$NAME" "$STATUS" "$IMAGE"
    done
    echo ""
    echo "  Expected container check:"
    for C in "${EXPECTED[@]}"; do
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${C}$"; then
            printf "    %-28s UP\n" "$C"
        else
            printf "    %-28s MISSING or STOPPED\n" "$C"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        fi
    done
fi

section "10. DISK SPACE SUMMARY"

printf "  %-32s %6s  %6s  %6s  %6s\n" "Mount" "Use%" "Used" "Avail" "Total"

print_df_row() {
    local MOUNT="$1" LABEL="${2:-}"
    df -h --output=pcent,used,avail,size "$MOUNT" 2>/dev/null | tail -1 | \
        awk -v lbl="${LABEL:-$MOUNT}" '{gsub(/%/,"",$1); printf "  %-32s %5s%%  %6s  %6s  %6s\n", lbl, $1, $2, $3, $4}'
}

print_df_row "/"             "/ (root)"
print_df_row "$NVME_MOUNT"   "/var/lib/docker (NVMe)"
timeout 5 ls "$NFS_MOUNT" >/dev/null 2>&1 \
    && print_df_row "$NFS_MOUNT" "/mnt/truenas (NFS)" \
    || printf "  %-32s %s\n" "/mnt/truenas (NFS)" "UNRESPONSIVE"

section "11. RECENT TIER-0 LOG (last 20 lines)"
TIER0_LOG="/var/log/tier0.log"
[ -f "$TIER0_LOG" ] && tail -20 "$TIER0_LOG" | sed 's/^/  /' \
    || echo "  ${TIER0_LOG} not found"

section "12. RECENT SCRIPT ACTIVITY"
# NOTE: db-dumps log lookup uses static path -- see known-issues.md
declare -A SCRIPT_LOGS=(
    ["monitor-backups"]="/var/log/tier0.log"
    ["check-nfs-health"]="/var/log/nfs-health.log"
    ["db-dumps"]="/var/log/db-dumps.log"
    ["filen-rclone"]="/var/log/filen-backup-$(date +%Y%m%d).log"
)
for NAME in "monitor-backups" "check-nfs-health" "db-dumps" "filen-rclone"; do
    LOG="${SCRIPT_LOGS[$NAME]}"
    if [ -f "$LOG" ]; then
        LAST=$(tail -1 "$LOG" 2>/dev/null | sed 's/^[[:space:]]*//' || echo "")
        LOG_AGE=$(( NOW - $(stat -c %Y "$LOG") ))
        printf "  %-22s last_run=%-10s  last_line: %s\n" \
            "${NAME}:" "$(fmt_age "$LOG_AGE") ago" "${LAST:0:60}"
    else
        printf "  %-22s log not found: %s\n" "${NAME}:" "$LOG"
    fi
done

section "SUMMARY"

if [ "$OVERALL" = "OK" ] && [ "$WARNINGS" -eq 0 ]; then
    echo "  STATUS:   OK -- all checks passed"
elif [ "$OVERALL" = "OK" ] && [ "$WARNINGS" -gt 0 ]; then
    echo "  STATUS:   DEGRADED -- ${WARNINGS} warning(s), no critical failures"
    OVERALL="DEGRADED"
else
    echo "  STATUS:   ACTION REQUIRED -- ${ISSUES} issue(s)  ${WARNINGS} warning(s)"
fi

echo ""
echo "  Issues   : ${ISSUES}"
echo "  Warnings : ${WARNINGS}"
echo "  Generated: $(date --iso-8601=seconds)"
echo "==================================================================="

} > "$REPORT"

SUBJECT="[HOMELAB DAILY] ${OVERALL} | ${DATE} | issues=${ISSUES} warn=${WARNINGS}"
mail -s "$SUBJECT" root < "$REPORT" 2>/dev/null || true

find /var/log -maxdepth 1 -name "homelab-daily-*.log" -mtime +90 -delete 2>/dev/null || true

echo "[DAILY-REPORT] Sent: ${SUBJECT}"
```
