#!/usr/bin/env bash
#
# update-integrity-chain.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Proxmox Host (192.168.178.127)
#
# PURPOSE:
#   SHA256-hashes the latest forensic dump and appends the result to the
#   integrity chain file. Uses flock to prevent race conditions.
#   The chain file is enforced append-only via chattr +a (set once at first run).
#
#   This creates a cryptographic chain of custody for all forensic dumps:
#     - Detects accidental modification of past dumps
#     - Detects dump deletion
#     - Detects chain tampering
#
# FIRST-RUN SETUP:
#   On first execution the chain file is created and chattr +a is applied.
#   After that, only appends are permitted -- even root cannot rewrite entries
#   without first running: chattr -a /root/forensic-history/dumps/integrity-chain.txt
#
# VERIFY THE CHAIN:
#   /usr/local/bin/verify-integrity.sh
#
# REMOVE APPEND-ONLY (only if rotating/resetting chain):
#   chattr -a /root/forensic-history/dumps/integrity-chain.txt
#   # make change, then re-enable:
#   chattr +a /root/forensic-history/dumps/integrity-chain.txt
#
# Cron (Proxmox host -- quarterly, immediately after forensic-dump.sh):
#   30 5 1 1,4,7,10 *   /usr/local/bin/update-integrity-chain.sh >> /var/log/integrity-chain.log 2>&1

set -euo pipefail

DUMP_DIR="/root/forensic-history/dumps"
CHAIN="${DUMP_DIR}/integrity-chain.txt"
LOCKFILE="${DUMP_DIR}/.integrity.lock"

fail() {
    echo "[INTEGRITY] FAIL: $1" >&2
    echo "Integrity chain update FAILED: $1" \
        | mail -s "[HOMELAB INTEGRITY FAIL] $1" root 2>/dev/null || true
    exit 1
}

# 1. Find the latest forensic dump
LATEST=$(ls -t "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | head -1 || true)
[ -z "$LATEST" ] && fail "No forensic dump found in ${DUMP_DIR} -- run forensic-dump.sh first"

# 2. Hash the dump
HASH=$(sha256sum "$LATEST" | awk '{print $1}') \
    || fail "sha256sum failed on ${LATEST}"

ENTRY="$(date -u +"%Y-%m-%dT%H:%M:%SZ") | ${LATEST} | ${HASH}"

# 3. Create chain file if it does not exist, then enforce append-only
if [ ! -f "$CHAIN" ]; then
    mkdir -p "$DUMP_DIR"
    touch "$CHAIN"
    # Set append-only flag -- requires e2fsprogs (chattr)
    if command -v chattr >/dev/null 2>&1; then
        chattr +a "$CHAIN" \
            && echo "[INTEGRITY] Append-only flag set on ${CHAIN}" \
            || echo "[INTEGRITY] WARN: chattr +a failed -- filesystem may not support it (e.g. ZFS/tmpfs)" >&2
    else
        echo "[INTEGRITY] WARN: chattr not available -- append-only not enforced" >&2
    fi
fi

# 4. Check whether this dump is already in the chain (idempotent re-runs)
if grep -qF "$LATEST" "$CHAIN" 2>/dev/null; then
    echo "[INTEGRITY] Already recorded: ${LATEST} -- skipping (idempotent)"
    exit 0
fi

# 5. Append entry under flock (prevents parallel write corruption)
(
    flock -x 200 || fail "Could not acquire lock on ${LOCKFILE}"
    echo "$ENTRY" >> "$CHAIN" \
        || fail "Append to chain failed -- append-only flag may be blocking a non-append open"
) 200>"$LOCKFILE"

echo "[INTEGRITY] Chain updated: ${ENTRY}"
exit 0
