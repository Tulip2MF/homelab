# verify-integrity.sh

Walks the integrity chain file and re-hashes every recorded forensic dump. Flags any dump that has been modified, deleted, or whose chain entry is malformed.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/verify-integrity.sh`
**Cron:** None — run manually, or called by `quarterly-report.sh`
**Classification:** Operator-Only

---

## Purpose

Provides tamper detection for the forensic dump history. After an incident, or as part of the quarterly review, run this script to confirm that no historical dump has been altered since it was recorded in the integrity chain.

Read-only — makes no changes to any file.

---

## How to Run

```bash
sudo /usr/local/bin/verify-integrity.sh 2>&1 | tee /var/log/integrity-verify-$(date +%F).log
```

---

## Possible Results Per Entry

| Status | Meaning |
|---|---|
| `[OK]` | File exists and hash matches the recorded value |
| `[MISSING]` | File has been deleted or moved |
| `[TAMPERED]` | File exists but its current hash does not match the recorded hash |

A `[MISSING]` result for old dumps is expected after `prune-forensic-history.sh` has run and removed them. This is correct and intentional — the chain records their former existence.

A `[TAMPERED]` result is never expected and requires immediate investigation.

---

## Append-Only Flag Check

At the end of the run, the script checks whether `integrity-chain.txt` still has the `chattr +a` append-only flag set. If the flag has been removed, the chain file itself could have been rewritten and the verification result cannot be fully trusted.

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/dumps/integrity-chain.txt` | The chain being verified |
| `/root/forensic-history/dumps/system-dump-*.txt` | Forensic dumps being re-hashed |

---

## Install

```bash
cp verify-integrity.sh /usr/local/bin/
chmod +x /usr/local/bin/verify-integrity.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# verify-integrity.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
# READ-ONLY:   makes no changes to any file
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)
# Run manually -- also called by quarterly-report.sh

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
    DATE=$(echo "$DATE"        | xargs)
    FILE=$(echo "$FILE"        | xargs)
    STORED_HASH=$(echo "$STORED_HASH" | xargs)

    [ -z "$FILE" ] || [ -z "$STORED_HASH" ] && {
        echo "[WARN] Malformed chain entry -- skipping: DATE='${DATE}' FILE='${FILE}'"
        FAIL=$(( FAIL + 1 ))
        continue
    }

    if [ ! -f "$FILE" ]; then
        echo "[MISSING] ${FILE}"
        echo "          Recorded: ${DATE} | hash: ${STORED_HASH}"
        MISSING=$(( MISSING + 1 ))
        FAIL=$(( FAIL + 1 ))
        continue
    fi

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
```
