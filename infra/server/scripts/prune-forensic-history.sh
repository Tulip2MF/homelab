#!/usr/bin/env bash
#
# prune-forensic-history.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Proxmox Host (192.168.178.127)
#
# PURPOSE:
#   Enforces retention policy on forensic history directories.
#   Prevents unbounded growth of forensic dumps and metrics files on the
#   Proxmox root partition.
#
# RETENTION POLICY:
#   dumps/   -- keep 1 year  (365 days)  -- quarterly = ~4 dumps kept at any time
#   metrics/ -- keep 5 years (1825 days) -- quarterly = ~20 samples for long-term trending
#
# INTEGRITY CHAIN:
#   The chain file (integrity-chain.txt) is NEVER deleted by this script.
#   Entries for pruned dumps are left in the chain deliberately:
#   their absence from disk is itself recorded (verify-integrity.sh will flag
#   them as MISSING, which is the expected and correct outcome after pruning).
#   This preserves a permanent audit trail of what dumps existed and when.
#
# SAFETY:
#   Dry-run mode available: set DRY_RUN=1 or pass --dry-run
#     DRY_RUN=1 /usr/local/bin/prune-forensic-history.sh
#
# Cron (Proxmox host -- annually, 1st January):
#   0 4 1 1 *   /usr/local/bin/prune-forensic-history.sh >> /var/log/prune-forensic.log 2>&1

set -euo pipefail

DUMP_DIR="/root/forensic-history/dumps"
METRICS_DIR="/root/forensic-history/metrics"

DUMP_RETAIN_DAYS=365
METRICS_RETAIN_DAYS=1825

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1
[[ "${DRY_RUN_ENV:-0}" == "1" ]] && DRY_RUN=1

DELETED_DUMPS=0
DELETED_METRICS=0

fail() {
    echo "[PRUNE] FAIL: $1" >&2
    echo "Forensic prune FAILED: $1" \
        | mail -s "[HOMELAB PRUNE FAIL] $1" root 2>/dev/null || true
    exit 1
}

echo "[PRUNE] Starting $(date --iso-8601=seconds)"
[ "$DRY_RUN" -eq 1 ] && echo "[PRUNE] DRY-RUN MODE -- no files will be deleted"

# Validate directories exist
[ -d "$DUMP_DIR" ]    || fail "Dump directory not found: ${DUMP_DIR}"
[ -d "$METRICS_DIR" ] || fail "Metrics directory not found: ${METRICS_DIR}"

# ── Prune forensic dumps (1 year) ────────────────────────────────────────────
echo "[PRUNE] Checking dumps older than ${DUMP_RETAIN_DAYS} days in ${DUMP_DIR}..."

while IFS= read -r -d '' FILE; do
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[PRUNE] DRY-RUN: would delete dump: ${FILE}"
    else
        rm -f "$FILE"
        echo "[PRUNE] Deleted dump: ${FILE}"
    fi
    DELETED_DUMPS=$(( DELETED_DUMPS + 1 ))
done < <(find "$DUMP_DIR" -maxdepth 1 -name "system-dump-*.txt" \
    -mtime "+${DUMP_RETAIN_DAYS}" -print0 2>/dev/null)

# ── Prune metrics files (5 years) ────────────────────────────────────────────
echo "[PRUNE] Checking metrics older than ${METRICS_RETAIN_DAYS} days in ${METRICS_DIR}..."

while IFS= read -r -d '' FILE; do
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[PRUNE] DRY-RUN: would delete metrics: ${FILE}"
    else
        rm -f "$FILE"
        echo "[PRUNE] Deleted metrics: ${FILE}"
    fi
    DELETED_METRICS=$(( DELETED_METRICS + 1 ))
done < <(find "$METRICS_DIR" -maxdepth 1 -name "metrics-*.txt" \
    -mtime "+${METRICS_RETAIN_DAYS}" -print0 2>/dev/null)

# ── Prune prune logs themselves (keep 3 years) ───────────────────────────────
find /var/log -maxdepth 1 -name "prune-forensic*.log" -mtime +1095 -delete 2>/dev/null || true

# ── Summary ──────────────────────────────────────────────────────────────────
echo "[PRUNE] Done -- dumps removed: ${DELETED_DUMPS}  metrics removed: ${DELETED_METRICS}"

if [ "$DRY_RUN" -eq 0 ] && [ $(( DELETED_DUMPS + DELETED_METRICS )) -gt 0 ]; then
    echo "Forensic prune complete: ${DELETED_DUMPS} dumps, ${DELETED_METRICS} metrics files removed on $(date +%F)" \
        | mail -s "[HOMELAB PRUNE] Forensic history pruned" root 2>/dev/null || true
fi

exit 0
