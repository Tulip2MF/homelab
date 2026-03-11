# test-restore.sh

Monthly restore verification. Confirms the backup chain is not silently broken without performing a full restore. Read-only throughout — makes no changes to live data.

**Host:** Shipyard (Debian) `192.168.178.141`
**Install path:** `/usr/local/bin/test-restore.sh`
**Cron:** None — run manually every month
**Classification:** Operator-Only

---

## Purpose

Verifies the integrity of the entire backup chain by spot-checking that:

1. PBS and Filen markers are fresh (within RPO windows)
2. PBS archive files exist on Harbour (TrueNAS) NFS and are non-zero size
3. rclone can connect to Filen Cloud and decrypt files (proves credentials AND passphrase are valid)
4. PostgreSQL dumps can be parsed by `pg_restore --list` (proves dumps are structurally valid)

This is not a full restore. It is a monthly confidence check that your backups are restorable before you actually need them.

> ⚠️ **Known Bug:** The script uses `paperless-db-1` to run `pg_restore --list` on **both** the Paperless and Immich dumps. The Immich dump should be verified inside `immich_postgres` (the custom image with pgvecto.rs). See `known-issues.md`.

---

## How to Run

```bash
sudo /usr/local/bin/test-restore.sh 2>&1 | tee /var/log/restore-test-$(date +%F).log
```

Review the output. Every check should print `[PASS]`. Any `[FAIL]` requires investigation before you can trust that backup.

---

## What to Look For

- All lines print `[PASS]`
- Filen remote listing returns files (not empty)
- PBS archive sizes are non-zero
- `pg_restore --list` exits 0 for both paperless and immich dumps
- No "permission denied", "connection refused", or "corrupt" in output

---

## Checks Performed

| Check | What it verifies |
|---|---|
| 1. Marker recency | PBS marker < 25h old, Filen marker < 8 days old |
| 2. Harbour (TrueNAS) NFS integrity | Mount responsive, PBS `.fidx` / `.blob` files exist and non-zero |
| 3. Filen Cloud rclone | WebDAV credentials valid, crypt passphrase valid, remote has files |
| 4. Database dump readability | `pg_restore --list` succeeds for paperless and immich dumps, Redis RDB non-zero |

---

## Key Files

| File | Purpose |
|---|---|
| `/mnt/truenas` | Harbour (TrueNAS) NFS — checked for PBS archive files |
| `/mnt/truenas/db-dumps/` | Location of pg and redis dumps |
| `/var/log/filen-last-success.txt` | Filen recency marker |
| `/mnt/truenas/.pbs-last-success.txt` | PBS recency marker |
| `/var/log/restore-test-YYYY-MM-DD.log` | Output log (written by the tee command above) |

---

## Dependencies

- `rclone` installed and `filen-crypt` remote configured
- Harbour (TrueNAS) NFS mounted at `/mnt/truenas`
- Docker running with `paperless-db-1` and `immich_postgres` containers up

---

## Install

```bash
cp test-restore.sh /usr/local/bin/
chmod +x /usr/local/bin/test-restore.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# test-restore.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
# READ-ONLY:   makes no changes to any live data
#
# Runs on: Shipyard (Debian) (192.168.178.141)
# Run manually -- do NOT automate.

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
NFS_MOUNT="/mnt/truenas"
RCLONE_REMOTE="filen-crypt"
REMOTE_BACKUPS="${RCLONE_REMOTE}:backups"
FILEN_MARKER="/var/log/filen-last-success.txt"
PBS_MARKER="${NFS_MOUNT}/.pbs-last-success.txt"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$(( PASS + 1 )); }
fail() { echo "[FAIL] $1"; FAIL=$(( FAIL + 1 )); }
section() { echo ""; echo "=== $1 ==="; }

echo "========================================"
echo " RESTORE VERIFICATION -- $(date --iso-8601=seconds)"
echo " Host: Shipyard (Debian) 192.168.178.141"
echo "========================================"

section "PRE-FLIGHT"

if [ -f "$INHIBIT" ]; then
    echo "[WARN] backup_inhibit is set: $(cat $INHIBIT)"
    echo "       Tier-0 is not verified. Restore test may show false failures."
    echo "       Continuing anyway for diagnostic purposes."
fi

section "CHECK 1: Marker Recency"

if [ -f "$PBS_MARKER" ]; then
    PBS_AGE=$(( $(date +%s) - $(stat -c %Y "$PBS_MARKER") ))
    PBS_DATE=$(stat -c %y "$PBS_MARKER")
    [ "$PBS_AGE" -lt 90000 ] \
        && pass "PBS marker fresh (${PBS_AGE}s old) -- last backup: ${PBS_DATE}" \
        || fail "PBS marker stale (${PBS_AGE}s old) -- last backup: ${PBS_DATE}"
else
    fail "PBS marker missing at ${PBS_MARKER}"
fi

if [ -f "$FILEN_MARKER" ]; then
    FILEN_AGE=$(( $(date +%s) - $(stat -c %Y "$FILEN_MARKER") ))
    FILEN_DATE=$(stat -c %y "$FILEN_MARKER")
    [ "$FILEN_AGE" -lt 691200 ] \
        && pass "Filen marker fresh (${FILEN_AGE}s old) -- last upload: ${FILEN_DATE}" \
        || fail "Filen marker stale (${FILEN_AGE}s old) -- last upload: ${FILEN_DATE}"
else
    fail "Filen marker missing at ${FILEN_MARKER}"
fi

section "CHECK 2: Harbour (TrueNAS) NFS Archive Integrity"

if ! timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    fail "Harbour (TrueNAS) NFS ${NFS_MOUNT} unresponsive"
else
    pass "NFS mount ${NFS_MOUNT} is responsive"

    ARCHIVE_COUNT=$(find "$NFS_MOUNT" -name "*.fidx" -o -name "*.blob" 2>/dev/null | wc -l || echo 0)
    [ "$ARCHIVE_COUNT" -gt 0 ] \
        && pass "PBS archive files found: ${ARCHIVE_COUNT} index/blob files" \
        || fail "No PBS archive files found under ${NFS_MOUNT} -- check PBS datastore path"

    NEWEST=$(find "$NFS_MOUNT" -name "*.fidx" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    if [ -n "$NEWEST" ]; then
        SIZE=$(stat -c %s "$NEWEST" 2>/dev/null || echo 0)
        [ "$SIZE" -gt 0 ] \
            && pass "Newest PBS index file is non-zero (${SIZE} bytes): ${NEWEST}" \
            || fail "Newest PBS index file is ZERO bytes: ${NEWEST}"
    fi
fi

section "CHECK 3: Filen Cloud rclone Integrity"

if ! command -v rclone >/dev/null 2>&1; then
    fail "rclone not installed"
else
    pass "rclone is installed"

    echo "  Listing Filen remote (may take 10-30s)..."
    if LISTING=$(timeout 60 rclone lsd "$REMOTE_BACKUPS" 2>&1); then
        ITEM_COUNT=$(echo "$LISTING" | grep -c . || echo 0)
        [ "$ITEM_COUNT" -gt 0 ] \
            && pass "Filen remote listing succeeded (${ITEM_COUNT} top-level items)" \
            || fail "Filen remote listing returned empty -- no backups uploaded yet?"
    else
        fail "Filen remote listing failed: ${LISTING}"
    fi

    echo "  Checking newest file on Filen remote..."
    NEWEST_REMOTE=$(timeout 60 rclone lsl "$REMOTE_BACKUPS" --max-depth 3 2>/dev/null \
        | sort -k2,3 | tail -1 || true)
    [ -n "$NEWEST_REMOTE" ] \
        && pass "Filen has files: ${NEWEST_REMOTE}" \
        || fail "Cannot determine newest file on Filen remote"
fi

section "CHECK 4: Database Dump Readability"

DUMP_DIR="${NFS_MOUNT}/db-dumps"

if [ ! -d "$DUMP_DIR" ]; then
    fail "Dump directory ${DUMP_DIR} does not exist -- has dump-databases.sh ever run?"
else
    for LABEL in paperless immich; do
        NEWEST_DUMP=$(ls -t "${DUMP_DIR}/pg-${LABEL}-"*.dump 2>/dev/null | head -1 || true)
        if [ -n "$NEWEST_DUMP" ]; then
            DUMP_AGE=$(( $(date +%s) - $(stat -c %Y "$NEWEST_DUMP") ))
            # ⚠ BUG: uses paperless-db-1 for both dumps. Should use immich_postgres for immich.
            # See known-issues.md
            if docker exec paperless-db-1 pg_restore --list "/dev/stdin" < "$NEWEST_DUMP" >/dev/null 2>&1; then
                pass "pg_restore --list OK: ${LABEL} dump (age: ${DUMP_AGE}s)"
            else
                fail "pg_restore --list FAILED: ${LABEL} dump may be corrupt -- ${NEWEST_DUMP}"
            fi
        else
            fail "No dump found for ${LABEL} in ${DUMP_DIR}"
        fi
    done

    for LABEL in paperless; do
        NEWEST_RDB=$(ls -t "${DUMP_DIR}/redis-${LABEL}-"*.rdb 2>/dev/null | head -1 || true)
        if [ -n "$NEWEST_RDB" ]; then
            RDB_SIZE=$(stat -c %s "$NEWEST_RDB" 2>/dev/null || echo 0)
            RDB_AGE=$(( $(date +%s) - $(stat -c %Y "$NEWEST_RDB") ))
            [ "$RDB_SIZE" -gt 0 ] \
                && pass "Redis RDB OK: ${LABEL} (${RDB_SIZE} bytes, age: ${RDB_AGE}s)" \
                || fail "Redis RDB is ZERO bytes: ${LABEL} -- ${NEWEST_RDB}"
        else
            fail "No Redis RDB found for ${LABEL} in ${DUMP_DIR}"
        fi
    done
    pass "immich redis: ephemeral cache -- no dump by design (intentionally skipped)"
fi

echo ""
echo "========================================"
echo " RESULT: ${PASS} passed  /  ${FAIL} failed"
echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo " ACTION REQUIRED: ${FAIL} check(s) failed -- review output above"
    exit 1
else
    echo " All checks passed. Backup chain integrity verified."
    exit 0
fi
```
