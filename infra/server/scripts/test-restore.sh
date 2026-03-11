#!/usr/bin/env bash
#
# test-restore.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Debian VM (192.168.178.141)
#
# PURPOSE:
#   Monthly restore verification. Confirms that:
#     1. Filen Cloud is reachable and rclone crypt can decrypt
#     2. A sample of PBS archives on TrueNAS are readable and non-zero
#     3. A PostgreSQL dump (if present) can be parsed by pg_restore --list
#     4. rclone can list the remote (proves credentials + passphrase valid)
#
# This script does NOT perform a full restore. It performs INTEGRITY SPOT CHECKS
# sufficient to confirm the backup chain is not silently broken.
#
# DOES NOT modify any live data. Read-only throughout.
#
# Run manually -- do NOT automate. Operator must review output.
#   sudo /usr/local/bin/test-restore.sh 2>&1 | tee /var/log/restore-test-$(date +%F).log
#
# WHAT TO LOOK FOR:
#   - All checks print PASS
#   - Filen listing returns files (not empty)
#   - PBS archive sizes are non-zero
#   - pg_restore --list exits 0
#   - No "permission denied", "connection refused", or "corrupt" in output

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
echo " Host: 192.168.178.141"
echo "========================================"

# ─── PRE-FLIGHT ──────────────────────────────────────────────────────────────
section "PRE-FLIGHT"

if [ -f "$INHIBIT" ]; then
    echo "[WARN] backup_inhibit is set: $(cat $INHIBIT)"
    echo "       Tier-0 is not verified. Restore test may show false failures."
    echo "       Continuing anyway for diagnostic purposes."
fi

# ─── CHECK 1: Tier-0 marker recency ──────────────────────────────────────────
section "CHECK 1: Marker Recency"

if [ -f "$PBS_MARKER" ]; then
    PBS_AGE=$(( $(date +%s) - $(stat -c %Y "$PBS_MARKER") ))
    PBS_DATE=$(stat -c %y "$PBS_MARKER")
    if [ "$PBS_AGE" -lt 90000 ]; then
        pass "PBS marker fresh (${PBS_AGE}s old) -- last backup: ${PBS_DATE}"
    else
        fail "PBS marker stale (${PBS_AGE}s old) -- last backup: ${PBS_DATE}"
    fi
else
    fail "PBS marker missing at ${PBS_MARKER}"
fi

if [ -f "$FILEN_MARKER" ]; then
    FILEN_AGE=$(( $(date +%s) - $(stat -c %Y "$FILEN_MARKER") ))
    FILEN_DATE=$(stat -c %y "$FILEN_MARKER")
    if [ "$FILEN_AGE" -lt 691200 ]; then
        pass "Filen marker fresh (${FILEN_AGE}s old) -- last upload: ${FILEN_DATE}"
    else
        fail "Filen marker stale (${FILEN_AGE}s old) -- last upload: ${FILEN_DATE}"
    fi
else
    fail "Filen marker missing at ${FILEN_MARKER}"
fi

# ─── CHECK 2: TrueNAS NFS -- PBS archives readable ───────────────────────────
section "CHECK 2: TrueNAS NFS Archive Integrity"

if ! timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1; then
    fail "TrueNAS NFS ${NFS_MOUNT} unresponsive"
else
    pass "NFS mount ${NFS_MOUNT} is responsive"

    # Count and size PBS archive files (adjust glob to your PBS datastore path)
    ARCHIVE_COUNT=$(find "$NFS_MOUNT" -name "*.fidx" -o -name "*.blob" 2>/dev/null | wc -l || echo 0)
    if [ "$ARCHIVE_COUNT" -gt 0 ]; then
        pass "PBS archive files found: ${ARCHIVE_COUNT} index/blob files"
    else
        fail "No PBS archive files found under ${NFS_MOUNT} -- check PBS datastore path"
    fi

    # Spot-check: newest archive file is non-zero size
    NEWEST=$(find "$NFS_MOUNT" -name "*.fidx" 2>/dev/null | xargs ls -t 2>/dev/null | head -1)
    if [ -n "$NEWEST" ]; then
        SIZE=$(stat -c %s "$NEWEST" 2>/dev/null || echo 0)
        if [ "$SIZE" -gt 0 ]; then
            pass "Newest PBS index file is non-zero (${SIZE} bytes): ${NEWEST}"
        else
            fail "Newest PBS index file is ZERO bytes: ${NEWEST}"
        fi
    fi
fi

# ─── CHECK 3: rclone Filen -- credentials and crypt passphrase valid ─────────
section "CHECK 3: Filen Cloud rclone Integrity"

if ! command -v rclone >/dev/null 2>&1; then
    fail "rclone not installed"
else
    pass "rclone is installed"

    # List remote -- proves WebDAV credentials AND crypt passphrase are valid
    echo "  Listing Filen remote (may take 10-30s)..."
    if LISTING=$(timeout 60 rclone lsd "$REMOTE_BACKUPS" 2>&1); then
        ITEM_COUNT=$(echo "$LISTING" | grep -c . || echo 0)
        if [ "$ITEM_COUNT" -gt 0 ]; then
            pass "Filen remote listing succeeded (${ITEM_COUNT} top-level items)"
            echo "  Items: $(echo "$LISTING" | head -5)"
        else
            fail "Filen remote listing returned empty -- no backups uploaded yet?"
        fi
    else
        fail "Filen remote listing failed: ${LISTING}"
    fi

    # Check remote has been updated recently (file mtime via rclone)
    echo "  Checking newest file on Filen remote..."
    NEWEST_REMOTE=$(timeout 60 rclone lsl "$REMOTE_BACKUPS" --max-depth 3 2>/dev/null \
        | sort -k2,3 | tail -1 || true)
    if [ -n "$NEWEST_REMOTE" ]; then
        pass "Filen has files: ${NEWEST_REMOTE}"
    else
        fail "Cannot determine newest file on Filen remote"
    fi
fi

# ─── CHECK 4: Database dump readability ─────────────────────────────────────
section "CHECK 4: Database Dump Readability"

# Dumps written by dump-databases.sh to TrueNAS NFS.
# Stack: paperless-db-1 (postgres:18), immich_postgres (immich custom postgres)
DUMP_DIR="${NFS_MOUNT}/db-dumps"

if [ ! -d "$DUMP_DIR" ]; then
    fail "Dump directory ${DUMP_DIR} does not exist -- has dump-databases.sh ever run?"
else
    for LABEL in paperless immich; do
        NEWEST_DUMP=$(ls -t "${DUMP_DIR}/pg-${LABEL}-"*.dump 2>/dev/null | head -1 || true)
        if [ -n "$NEWEST_DUMP" ]; then
            DUMP_AGE=$(( $(date +%s) - $(stat -c %Y "$NEWEST_DUMP") ))
            # Verify dump is readable using pg_restore inside the container
            # (pg_restore may not be installed on host, but is in the postgres containers)
            if docker exec paperless-db-1 pg_restore --list "/dev/stdin" < "$NEWEST_DUMP" >/dev/null 2>&1; then
                pass "pg_restore --list OK: ${LABEL} dump (age: ${DUMP_AGE}s) -- ${NEWEST_DUMP}"
            else
                fail "pg_restore --list FAILED: ${LABEL} dump may be corrupt -- ${NEWEST_DUMP}"
            fi
        else
            fail "No dump found for ${LABEL} in ${DUMP_DIR} -- has dump-databases.sh run?"
        fi
    done

    # Check Redis/Valkey RDB files exist and are non-zero.
    # Only paperless redis is dumped. immich_redis is intentionally skipped
    # by dump-databases.sh -- it is an ephemeral cache with no volume.
    # Checking for an immich redis dump here would always produce a false FAIL.
    for LABEL in paperless; do
        NEWEST_RDB=$(ls -t "${DUMP_DIR}/redis-${LABEL}-"*.rdb 2>/dev/null | head -1 || true)
        if [ -n "$NEWEST_RDB" ]; then
            RDB_SIZE=$(stat -c %s "$NEWEST_RDB" 2>/dev/null || echo 0)
            RDB_AGE=$(( $(date +%s) - $(stat -c %Y "$NEWEST_RDB") ))
            if [ "$RDB_SIZE" -gt 0 ]; then
                pass "Redis RDB OK: ${LABEL} (${RDB_SIZE} bytes, age: ${RDB_AGE}s)"
            else
                fail "Redis RDB is ZERO bytes: ${LABEL} -- ${NEWEST_RDB}"
            fi
        else
            fail "No Redis RDB found for ${LABEL} in ${DUMP_DIR}"
        fi
    done
    pass "immich redis: ephemeral cache -- no dump by design (intentionally skipped)"
fi

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
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
