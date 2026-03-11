#!/usr/bin/env bash
#
# homelab-daily-report.sh
#
# ROLE:        reporting only
# AUTHORITY:   none
# FAIL MODE:   open (report always sends, even if sections fail)
# AUTO-REPAIR: forbidden
# READ-ONLY:   this script never sets inhibit, never restarts services,
#              never modifies system state. It only reads and reports.
#
# Runs on: Debian VM (192.168.178.141, hostname: shipyard)
#
# PURPOSE:
#   Consolidated daily status email covering the full homelab backup and
#   infrastructure chain. Complements (does NOT replace) the reactive alert
#   emails sent by monitor-backups.sh, check-nfs-health.sh, dump-databases.sh,
#   and backup-filen-rclone.sh on failure.
#
#   Those scripts alert immediately when something breaks.
#   This script gives you a single daily snapshot of everything at once,
#   including items that are OK, degraded, or pending.
#
# DUPLICATE AVOIDANCE:
#   This script does NOT re-evaluate Tier-0 (that is monitor-backups.sh's role).
#   It reads the inhibit file and heartbeat to REPORT Tier-0 state -- it does
#   not set or clear them.
#   It does NOT re-run NVMe SMART checks (check-nvme-health.sh owns that on
#   the Proxmox host). It reads the last line of the nvme-health.log instead.
#   It does NOT re-run NFS health checks (check-nfs-health.sh owns that).
#   It reads state; all enforcement is left to the responsible scripts.
#
# NETWORK MAP:
#   Proxmox host  192.168.178.127  (NTP master, NVMe health log source)
#   TrueNAS VM    192.168.178.139  (backup store, NFS server, ZFS pool)
#   PBS Mini PC   192.168.178.142  (nightly VM backups)
#   Debian VM     192.168.178.141  (THIS HOST -- apps, rclone, daily report)
#
# Cron (Debian VM -- daily at 07:00, after PBS marker window closes):
#   0 7 * * *   /usr/local/bin/homelab-daily-report.sh >> /var/log/homelab-daily.log 2>&1

set -euo pipefail
export LC_ALL=C

# ─── Configuration ────────────────────────────────────────────────────────────

DATE=$(date +%F)
NOW=$(date +%s)
REPORT="/var/log/homelab-daily-${DATE}.log"

INHIBIT="/var/run/backup_inhibit"
HEARTBEAT_FILE="/var/run/tier0_heartbeat"
HEARTBEAT_MAX_AGE=400          # seconds -- must match monitor-backups.sh

NFS_MOUNT="/mnt/truenas"
TRUENAS_HOST="192.168.178.139"
TRUENAS_SSH_USER="healthcheck"
TRUENAS_SSH_KEY="/root/.ssh/id_ed25519_truenas"
PROXMOX_NTP_IP="192.168.178.127"

PBS_MARKER="${NFS_MOUNT}/.pbs-last-success.txt"
FILEN_MARKER="/var/log/filen-last-success.txt"
DUMP_DIR="${NFS_MOUNT}/db-dumps"
NVME_MOUNT="/var/lib/docker"

# RPO windows -- must match values in monitor-backups.sh
PBS_RPO_MAX=90000      # 25 hours
FILEN_RPO_MAX=691200   # 8 days (weekly upload + margin)
DB_RPO_MAX=93600       # 26 hours

# Capacity thresholds -- must match monitor-backups.sh
MAX_CAPACITY_OK=70
WARN_CAPACITY=75
CRIT_CAPACITY=85

# NVMe health log written by check-nvme-health.sh on Proxmox host.
# This VM reads the log over NFS if available, or skips with a note.
# The log is NOT on this VM -- it is on 192.168.178.127.
# To enable: mount or rsync the log to this path, or SSH to Proxmox.
NVME_HEALTH_LOG="/var/log/nvme-health.log"   # local path if log is forwarded

# ─── Counters ────────────────────────────────────────────────────────────────

ISSUES=0        # anything that needs operator attention
WARNINGS=0      # degraded but not failed
OVERALL="OK"

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Print a section header
section() {
    echo ""
    echo "-------------------------------------------------------------------"
    printf "  %s\n" "$1"
    echo "-------------------------------------------------------------------"
}

# Format seconds into human-readable age
fmt_age() {
    local S="$1"
    if   [ "$S" -lt 60 ];    then echo "${S}s"
    elif [ "$S" -lt 3600 ];  then echo "$(( S/60 ))m"
    elif [ "$S" -lt 86400 ]; then echo "$(( S/3600 ))h $(( (S%3600)/60 ))m"
    else                          echo "$(( S/86400 ))d $(( (S%86400)/3600 ))h"
    fi
}

# Capacity label with threshold annotation
cap_label() {
    local PCT="$1"
    if   [ "$PCT" -ge "$CRIT_CAPACITY" ];    then echo "${PCT}%  [CRITICAL >= ${CRIT_CAPACITY}%]";    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    elif [ "$PCT" -ge "$WARN_CAPACITY" ];    then echo "${PCT}%  [WARNING >= ${WARN_CAPACITY}%]";     WARNINGS=$(( WARNINGS+1 ))
    elif [ "$PCT" -ge "$MAX_CAPACITY_OK" ];  then echo "${PCT}%  [DEGRADED >= ${MAX_CAPACITY_OK}%]";  WARNINGS=$(( WARNINGS+1 ))
    else                                          echo "${PCT}%  [OK]"
    fi
}

# Check a marker file against an RPO window
# Usage: check_marker <path> <rpo_seconds> <label>
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
    local AGE_HUMAN
    AGE_HUMAN=$(fmt_age "$AGE")
    local LAST_DATE
    LAST_DATE=$(date -d "@${TS}" "+%F %T" 2>/dev/null || echo "unknown")
    if [ "$AGE" -lt "$RPO" ]; then
        printf "  %-28s OK       age=%s  last=%s\n" "${LABEL}:" "$AGE_HUMAN" "$LAST_DATE"
    else
        printf "  %-28s STALE    age=%s  last=%s  (RPO=%s)\n" \
            "${LABEL}:" "$AGE_HUMAN" "$LAST_DATE" "$(fmt_age "$RPO")"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    fi
}

# ─── Build report ─────────────────────────────────────────────────────────────

mkdir -p /var/log

{

# ══════════════════════════════════════════════════════════════════════════════
echo "==================================================================="
echo "  HOMELAB DAILY HEALTH REPORT"
printf "  Host : %s (192.168.178.141)\n" "$(hostname)"
echo "  Date : ${DATE}  $(date +%T)"
echo "==================================================================="

# ══════════════════════════════════════════════════════════════════════════════
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

# Heartbeat freshness -- confirms monitor-backups.sh cron is alive
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
    echo "             Expected at: ${HEARTBEAT_FILE}"
    WARNINGS=$(( WARNINGS+1 ))
fi

# ══════════════════════════════════════════════════════════════════════════════
section "2. POWER (UPS)"

# This reads the live UPS state from NUT. The UPS is physically connected to
# Proxmox (192.168.178.127) which acts as NUT master. This VM is the NUT slave.
# monitor-backups.sh will block Tier-0 on UPS failure once NUT setup is complete.

if ! command -v upsc >/dev/null 2>&1; then
    echo "  STATUS:   PENDING  -- upsc not installed (apt install nut-client)"
    WARNINGS=$(( WARNINGS+1 ))
elif ! upsc -l 2>/dev/null | grep -q .; then
    echo "  STATUS:   PENDING  -- NUT not reachable or no UPS configured on Proxmox"
    echo "            UPS USB cable may not yet be connected to 192.168.178.127"
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
        echo "  UPS name: ${UPS_NAME}  (source: ${PROXMOX_NTP_IP})"
    else
        echo "  STATUS:   UNKNOWN  -- upsc -l returned no devices"
        WARNINGS=$(( WARNINGS+1 ))
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "3. TIME SYNC (NTP)"

# All VMs must sync from Proxmox (192.168.178.127) as NTP master.
# Independent external sync would break PBS snapshot ordering.

if ! command -v chronyc >/dev/null 2>&1; then
    echo "  STATUS:   ERROR  -- chronyc not found (apt install chrony)"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    NTP_SOURCE=$(chronyc sources 2>/dev/null | awk '/^\*/ {print $2}' || echo "")
    OFFSET_RAW=$(chronyc tracking 2>/dev/null | grep "Last offset" \
        | awk '{print $4}' || echo "0")
    # Remove sign, convert to integer ms for display
    OFFSET_ABS=$(echo "$OFFSET_RAW" | awk '{v=$1; if(v<0)v=-v; printf "%.3f", v}' 2>/dev/null || echo "?")
    LAST_SYNC=$(chronyc tracking 2>/dev/null | grep "Last update time" \
        | awk '{print int($5)}' || echo "0")

    if [ -z "$NTP_SOURCE" ]; then
        echo "  STATUS:   FAILED  -- no active NTP source (chrony not locked)"
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    elif [ "$NTP_SOURCE" != "$PROXMOX_NTP_IP" ]; then
        echo "  STATUS:   WRONG SOURCE"
        echo "  Source:   ${NTP_SOURCE}  (expected: ${PROXMOX_NTP_IP})"
        echo "  All VMs must sync FROM Proxmox NTP master, not external servers."
        ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
    else
        echo "  STATUS:   OK  -- syncing from Proxmox NTP master (${PROXMOX_NTP_IP})"
    fi
    echo "  Offset:   ${OFFSET_ABS}s   Last sync: $(fmt_age "$LAST_SYNC") ago"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "4. TRUENAS STORAGE (192.168.178.139)"

NFS_OK=0

# 4a. NFS mount responsiveness
if ! timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    echo "  NFS mount:    UNRESPONSIVE  (${NFS_MOUNT})"
    echo "                Possible D-state hung mount. Check TrueNAS and network."
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    MOUNT_SOURCE=$(findmnt -n -o SOURCE "$NFS_MOUNT" 2>/dev/null || echo "unknown")
    echo "  NFS mount:    OK            ${NFS_MOUNT}  source=${MOUNT_SOURCE}"
    NFS_OK=1
fi

# 4b. ZFS pool health via SSH (same SSH key used by monitor-backups.sh)
POOL_STATE=$(ssh -i "$TRUENAS_SSH_KEY" \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    "${TRUENAS_SSH_USER}@${TRUENAS_HOST}" \
    "sudo zpool list -H -o health tank" 2>/dev/null) || POOL_STATE=""

if [ -z "$POOL_STATE" ]; then
    echo "  ZFS pool:     UNKNOWN       Cannot reach TrueNAS via SSH"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
elif [ "$POOL_STATE" != "ONLINE" ]; then
    echo "  ZFS pool:     ${POOL_STATE}  [DEGRADED -- archives may be at risk]"
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    # Also pull pool size/used/free for the report
    POOL_DETAIL=$(ssh -i "$TRUENAS_SSH_KEY" \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        "${TRUENAS_SSH_USER}@${TRUENAS_HOST}" \
        "sudo zpool list -H -o name,size,alloc,free,capacity,health tank" 2>/dev/null) || POOL_DETAIL=""
    echo "  ZFS pool:     ONLINE"
    [ -n "$POOL_DETAIL" ] && echo "  Pool detail:  ${POOL_DETAIL}"
fi

# 4c. TrueNAS capacity (via NFS df)
if [ "$NFS_OK" -eq 1 ]; then
    TRUENAS_PCT=$(df -P "$NFS_MOUNT" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || TRUENAS_PCT=""
    TRUENAS_DF=$(df -h "$NFS_MOUNT" 2>/dev/null \
        | awk 'NR==2 {print "used="$3"  avail="$4"  total="$2}') || TRUENAS_DF=""
    if [ -n "$TRUENAS_PCT" ]; then
        printf "  Capacity:     %s\n" "$(cap_label "$TRUENAS_PCT")"
        [ -n "$TRUENAS_DF" ] && echo "                ${TRUENAS_DF}"
    else
        echo "  Capacity:     UNKNOWN  (df failed)"
        WARNINGS=$(( WARNINGS+1 ))
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "5. DOCKER RUNTIME STORAGE (NVMe /var/lib/docker)"

# This partition hosts all Docker container volumes.
# check-nvme-health.sh on the Proxmox host monitors SMART + ZFS rpool.
# Here we report the partition capacity and mount state only.

if ! mountpoint -q "$NVME_MOUNT" 2>/dev/null; then
    echo "  Mount:        NOT MOUNTED  (${NVME_MOUNT})"
    echo "                Docker volumes are unavailable."
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    NVME_PCT=$(df -P "$NVME_MOUNT" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}') || NVME_PCT=0
    NVME_DF=$(df -h "$NVME_MOUNT" 2>/dev/null \
        | awk 'NR==2 {print "used="$3"  avail="$4"  total="$2}') || NVME_DF=""
    printf "  Capacity:     %s\n" "$(cap_label "$NVME_PCT")"
    [ -n "$NVME_DF" ] && echo "                ${NVME_DF}"
fi

# NVMe SMART summary -- read from the log written by check-nvme-health.sh.
# That script runs on the Proxmox host (192.168.178.127), not this VM.
# If the log is available locally (e.g. forwarded via syslog or rsync), show it.
# Otherwise note that it must be checked directly on 192.168.178.127.
if [ -f "$NVME_HEALTH_LOG" ]; then
    NVME_LAST=$(tail -1 "$NVME_HEALTH_LOG" 2>/dev/null || echo "")
    [ -n "$NVME_LAST" ] && echo "  SMART log:    ${NVME_LAST}"
else
    echo "  SMART/rpool:  check-nvme-health.sh runs on Proxmox (192.168.178.127)"
    echo "                Log: /var/log/nvme-health.log on that host"
    echo "                To forward: add rsync or remote syslog from Proxmox"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "6. PBS BACKUP SLA"

check_marker "$PBS_MARKER" "$PBS_RPO_MAX" "PBS last backup"

# Show marker content if available
if [ -f "$PBS_MARKER" ]; then
    PBS_CONTENT=$(timeout 5 cat "$PBS_MARKER" 2>/dev/null | head -1 || echo "")
    [ -n "$PBS_CONTENT" ] && echo "  Marker text:  ${PBS_CONTENT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "7. FILEN CLOUD BACKUP SLA"

check_marker "$FILEN_MARKER" "$FILEN_RPO_MAX" "Filen last upload"

if [ -f "$FILEN_MARKER" ]; then
    FILEN_CONTENT=$(cat "$FILEN_MARKER" 2>/dev/null | head -1 || echo "")
    [ -n "$FILEN_CONTENT" ] && echo "  Marker text:  ${FILEN_CONTENT}"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "8. DATABASE DUMPS"

if ! timeout 5 ls "$DUMP_DIR" >/dev/null 2>&1; then
    echo "  Dump directory: UNAVAILABLE  (${DUMP_DIR})"
    echo "  NFS may be unresponsive or dump-databases.sh has not yet run."
    ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
else
    echo "  Directory: ${DUMP_DIR}"
    echo ""

    # Postgres dumps
    for LABEL in paperless immich; do
        NEWEST=$(ls -t "${DUMP_DIR}/pg-${LABEL}-"*.dump 2>/dev/null | head -1 || echo "")
        if [ -z "$NEWEST" ]; then
            printf "  %-10s pg dump:   MISSING\n" "${LABEL}"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        else
            TS=$(timeout 5 stat -c %Y "$NEWEST" 2>/dev/null || echo 0)
            AGE=$(( NOW - TS ))
            SZ=$(du -sh "$NEWEST" 2>/dev/null | cut -f1 || echo "?")
            LAST_DATE=$(date -d "@${TS}" "+%F %T" 2>/dev/null || echo "unknown")
            if [ "$AGE" -lt "$DB_RPO_MAX" ]; then
                printf "  %-10s pg dump:   OK       age=%-8s  size=%-8s  file=%s\n" \
                    "$LABEL" "$(fmt_age "$AGE")" "$SZ" "$(basename "$NEWEST")"
            else
                printf "  %-10s pg dump:   STALE    age=%-8s  size=%-8s  last=%s\n" \
                    "$LABEL" "$(fmt_age "$AGE")" "$SZ" "$LAST_DATE"
                ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
            fi
        fi
    done

    echo ""

    # Redis/Valkey RDB dumps
    for LABEL in paperless; do        # immich_redis is intentionally ephemeral -- no dump
        NEWEST=$(ls -t "${DUMP_DIR}/redis-${LABEL}-"*.rdb 2>/dev/null | head -1 || echo "")
        if [ -z "$NEWEST" ]; then
            printf "  %-10s redis rdb: MISSING\n" "$LABEL"
            ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
        else
            TS=$(timeout 5 stat -c %Y "$NEWEST" 2>/dev/null || echo 0)
            AGE=$(( NOW - TS ))
            SZ=$(du -sh "$NEWEST" 2>/dev/null | cut -f1 || echo "?")
            if [ "$AGE" -lt "$DB_RPO_MAX" ]; then
                printf "  %-10s redis rdb: OK       age=%-8s  size=%-8s  file=%s\n" \
                    "$LABEL" "$(fmt_age "$AGE")" "$SZ" "$(basename "$NEWEST")"
            else
                printf "  %-10s redis rdb: STALE    age=%-8s  size=%-8s\n" \
                    "$LABEL" "$(fmt_age "$AGE")" "$SZ"
                ISSUES=$(( ISSUES+1 )); OVERALL="ACTION REQUIRED"
            fi
        fi
    done
    echo "  (immich redis: ephemeral cache -- no dump by design)"

    # Retention summary
    PG_COUNT=$(ls "${DUMP_DIR}"/pg-*.dump 2>/dev/null | wc -l || echo 0)
    RDB_COUNT=$(ls "${DUMP_DIR}"/redis-*.rdb 2>/dev/null | wc -l || echo 0)
    echo ""
    echo "  Retained dumps: ${PG_COUNT} pg  |  ${RDB_COUNT} rdb  (14-day retention)"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "9. DOCKER CONTAINER STATUS"

if ! command -v docker >/dev/null 2>&1; then
    echo "  Docker not found on this host."
else
    # Running containers
    RUNNING=$(docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null || echo "")
    # Expected containers (from dump-databases.sh stack definition)
    EXPECTED=(paperless-db-1 paperless-broker-1 immich_postgres immich_redis)

    if [ -z "$RUNNING" ]; then
        echo "  No running containers found."
        WARNINGS=$(( WARNINGS+1 ))
    else
        echo "  Running containers:"
        echo "$RUNNING" | while IFS=$'\t' read -r NAME STATUS IMAGE; do
            printf "    %-28s %-20s  %s\n" "$NAME" "$STATUS" "$IMAGE"
        done
    fi

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

    # Stopped/exited containers
    STOPPED=$(docker ps -a --filter status=exited --format '{{.Names}}\t{{.Status}}' 2>/dev/null || echo "")
    if [ -n "$STOPPED" ]; then
        echo ""
        echo "  Stopped/exited containers:"
        echo "$STOPPED" | while IFS=$'\t' read -r NAME STATUS; do
            printf "    %-28s %s\n" "$NAME" "$STATUS"
        done
        WARNINGS=$(( WARNINGS+1 ))
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
section "10. DISK SPACE SUMMARY"

printf "  %-32s %6s  %6s  %6s  %6s\n" "Mount" "Use%" "Used" "Avail" "Total"
printf "  %-32s %6s  %6s  %6s  %6s\n" \
    "────────────────────────────────" "──────" "──────" "──────" "──────"

print_df_row() {
    local MOUNT="$1" LABEL="${2:-}"
    local DISPLAY="${LABEL:-$MOUNT}"
    if mountpoint -q "$MOUNT" 2>/dev/null || [ -d "$MOUNT" ]; then
        df -h --output=pcent,used,avail,size "$MOUNT" 2>/dev/null | tail -1 | \
            awk -v lbl="$DISPLAY" '{gsub(/%/,"",$1); printf "  %-32s %5s%%  %6s  %6s  %6s\n", lbl, $1, $2, $3, $4}'
    fi
}

print_df_row "/"             "/ (root)"
print_df_row "/var/log"      "/var/log"
print_df_row "$NVME_MOUNT"   "/var/lib/docker (NVMe)"
if timeout 5 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    print_df_row "$NFS_MOUNT" "/mnt/truenas (NFS)"
else
    printf "  %-32s %s\n" "/mnt/truenas (NFS)" "UNRESPONSIVE"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "11. RECENT TIER-0 LOG (last 20 lines)"

TIER0_LOG="/var/log/tier0.log"
if [ -f "$TIER0_LOG" ]; then
    tail -20 "$TIER0_LOG" | sed 's/^/  /'
else
    echo "  ${TIER0_LOG} not found -- monitor-backups.sh may not have run yet"
fi

# ══════════════════════════════════════════════════════════════════════════════
section "12. RECENT SCRIPT ACTIVITY"

# Show last line from each script's log to confirm they ran recently
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

# ══════════════════════════════════════════════════════════════════════════════
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
echo ""
echo "==================================================================="
echo "  Note: This report reads existing state."
echo "  Reactive alert emails are sent immediately on failure by:"
echo "    monitor-backups.sh  (Tier-0 evaluator -- every 5 min)"
echo "    check-nfs-health.sh (NFS -- hourly)"
echo "    dump-databases.sh   (DB dumps -- nightly)"
echo "    backup-filen-rclone.sh (cloud upload -- weekly)"
echo "==================================================================="

} > "$REPORT"

# ─── Send email ───────────────────────────────────────────────────────────────

SUBJECT="[HOMELAB DAILY] ${OVERALL} | ${DATE} | issues=${ISSUES} warn=${WARNINGS}"
mail -s "$SUBJECT" root < "$REPORT" 2>/dev/null || true

# ─── Rotate logs (90 days) ────────────────────────────────────────────────────
find /var/log -maxdepth 1 -name "homelab-daily-*.log" -mtime +90 -delete 2>/dev/null || true

echo "[DAILY-REPORT] Sent: ${SUBJECT}"
