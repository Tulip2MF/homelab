#!/usr/bin/env bash
#
# verify-integrity.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Proxmox Host (192.168.178.127)
#
# PURPOSE:
#   Walks the integrity chain file and re-hashes every recorded forensic dump.
#   Flags any dump that has been modified, deleted, or whose chain entry is corrupt.
#
# USAGE:
#   Run manually at any time -- especially before/after an incident.
#   sudo /usr/local/bin/verify-integrity.sh 2>&1 | tee /var/log/integrity-verify-$(date +%F).log
#
# WHAT TO LOOK FOR:
#   - All entries print OK
#   - No "MISSING" or "TAMPERED" lines
#   - Entry count matches your expected number of quarterly dumps
#
# READ-ONLY. Makes no changes to any file.

set -euo pipefail

DUMP_DIR="/root/forensic-history/dumps"
CHAIN="${DUMP_DIR}/integrity-chain.txt"

PASS=0
FAIL=0
MISSING=0

echo "========================================"
echo " INTEGRITY CHAIN VERIFICATION"
echo " $(date --iso-8601=seconds)"
echo " Chain: ${CHAIN}"
echo "========================================"

if [ ! -f "$CHAIN" ]; then
    echo "[FAIL] Integrity chain not found at ${CHAIN}"
    echo "       Run update-integrity-chain.sh after the next forensic-dump.sh"
    exit 1
fi

TOTAL=$(grep -c '|' "$CHAIN" 2>/dev/null || echo 0)
echo " Entries in chain: ${TOTAL}"
echo ""

while IFS="|" read -r DATE FILE STORED_HASH; do
    # Trim whitespace from each field
    DATE=$(echo "$DATE"        | xargs)
    FILE=$(echo "$FILE"        | xargs)
    STORED_HASH=$(echo "$STORED_HASH" | xargs)

    # Skip blank or malformed lines
    [ -z "$FILE" ] || [ -z "$STORED_HASH" ] && {
        echo "[WARN] Malformed chain entry -- skipping: DATE='${DATE}' FILE='${FILE}'"
        FAIL=$(( FAIL + 1 ))
        continue
    }

    # Check file exists
    if [ ! -f "$FILE" ]; then
        echo "[MISSING] ${FILE}"
        echo "          Recorded: ${DATE} | hash: ${STORED_HASH}"
        MISSING=$(( MISSING + 1 ))
        FAIL=$(( FAIL + 1 ))
        continue
    fi

    # Re-hash and compare
    CURRENT_HASH=$(sha256sum "$FILE" | awk '{print $1}')

    if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
        echo "[OK]     ${FILE}"
        echo "         Recorded: ${DATE} | hash: ${STORED_HASH}"
        PASS=$(( PASS + 1 ))
    else
        echo "[TAMPERED] ${FILE}"
        echo "           Recorded hash : ${STORED_HASH}"
        echo "           Current hash  : ${CURRENT_HASH}"
        FAIL=$(( FAIL + 1 ))
    fi

done < "$CHAIN"

echo ""
echo "========================================"
echo " RESULT: ${PASS} OK  |  ${MISSING} missing  |  ${FAIL} failed"
echo "========================================"

# Optional: verify the chain file itself has append-only flag
if command -v lsattr >/dev/null 2>&1; then
    ATTRS=$(lsattr "$CHAIN" 2>/dev/null | awk '{print $1}')
    if echo "$ATTRS" | grep -q 'a'; then
        echo " Append-only flag: SET (tamper-resistant)"
    else
        echo " Append-only flag: NOT SET -- chain file is unprotected"
        echo " To fix: chattr +a ${CHAIN}"
    fi
fi

echo "========================================"

if [ "$FAIL" -gt 0 ]; then
    echo " ACTION REQUIRED: ${FAIL} integrity failure(s) detected"
    exit 1
fi

echo " All entries verified. Integrity chain is intact."
exit 0
