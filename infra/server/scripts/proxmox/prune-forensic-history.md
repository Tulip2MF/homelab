# prune-forensic-history.sh

Enforces retention policy on the forensic history directories. Prevents unbounded growth of forensic dumps and metrics files on the Proxmox root partition.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/prune-forensic-history.sh`
**Cron:** `0 4 1 1 *   /usr/local/bin/prune-forensic-history.sh >> /var/log/prune-forensic.log 2>&1`
**Classification:** Executor

---

## Purpose

Forensic dumps and metrics files accumulate quarterly. Without pruning, they would grow indefinitely on the Proxmox root partition. This script runs annually on 1st January and removes files beyond the retention window.

---

## Retention Policy

| Directory | Retention | Reasoning |
|---|---|---|
| `dumps/` | 365 days (1 year) | Quarterly cadence → ~4 dumps retained at any time |
| `metrics/` | 1825 days (5 years) | 20 samples for long-term trending in `predict-capacity.sh` |

---

## Integrity Chain Preservation

The integrity chain file (`integrity-chain.txt`) is **never deleted** by this script. Entries for pruned dumps are left in the chain deliberately — their absence from disk is the expected and correct outcome. `verify-integrity.sh` will flag them as `[MISSING]`, which is the recorded evidence that those dumps existed and were pruned, not that they were tampered with.

---

## Dry-Run Mode

Run with `--dry-run` or set `DRY_RUN=1` to preview what would be deleted without actually deleting anything:

```bash
# Preview
/usr/local/bin/prune-forensic-history.sh --dry-run

# Or with environment variable
DRY_RUN=1 /usr/local/bin/prune-forensic-history.sh
```

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/dumps/` | Forensic dump files — pruned at 365 days |
| `/root/forensic-history/metrics/` | Metrics files — pruned at 1825 days |
| `/root/forensic-history/dumps/integrity-chain.txt` | Never pruned |
| `/var/log/prune-forensic.log` | Cron output log — rotated after 3 years |

---

## Install

```bash
cp prune-forensic-history.sh /usr/local/bin/
chmod +x /usr/local/bin/prune-forensic-history.sh
```

Add to crontab on Proxmox (`crontab -e`):
```
0 4 1 1 *   /usr/local/bin/prune-forensic-history.sh >> /var/log/prune-forensic.log 2>&1
```

---

## Script

```bash
#!/usr/bin/env bash
#
# prune-forensic-history.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)
# Cron (annually, 1st January):
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

[ -d "$DUMP_DIR" ]    || fail "Dump directory not found: ${DUMP_DIR}"
[ -d "$METRICS_DIR" ] || fail "Metrics directory not found: ${METRICS_DIR}"

# Prune forensic dumps (1 year)
echo "[PRUNE] Checking dumps older than ${DUMP_RETAIN_DAYS} days..."
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

# Prune metrics files (5 years)
echo "[PRUNE] Checking metrics older than ${METRICS_RETAIN_DAYS} days..."
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

# Rotate prune logs (keep 3 years)
find /var/log -maxdepth 1 -name "prune-forensic*.log" -mtime +1095 -delete 2>/dev/null || true

echo "[PRUNE] Done -- dumps removed: ${DELETED_DUMPS}  metrics removed: ${DELETED_METRICS}"

if [ "$DRY_RUN" -eq 0 ] && [ $(( DELETED_DUMPS + DELETED_METRICS )) -gt 0 ]; then
    echo "Forensic prune complete: ${DELETED_DUMPS} dumps, ${DELETED_METRICS} metrics files removed on $(date +%F)" \
        | mail -s "[HOMELAB PRUNE] Forensic history pruned" root 2>/dev/null || true
fi

exit 0
```
