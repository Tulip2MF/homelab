# update-integrity-chain.sh

SHA256-hashes the latest forensic dump and appends the result to the integrity chain file. Creates a cryptographic chain of custody for all quarterly forensic dumps.

**Host:** Proxmox Host `192.168.178.127`
**Install path:** `/usr/local/bin/update-integrity-chain.sh`
**Cron:** `30 5 1 1,4,7,10 *   /usr/local/bin/update-integrity-chain.sh >> /var/log/integrity-chain.log 2>&1`
**Classification:** Executor

---

## Purpose

After each quarterly `forensic-dump.sh` run, this script hashes the new dump file and appends the entry to `integrity-chain.txt`. The chain file is set to append-only (`chattr +a`) so entries cannot be rewritten or deleted without explicitly removing the filesystem attribute.

This lets `verify-integrity.sh` later confirm that no historical dump has been modified or deleted since it was recorded.

It is also called automatically by `forensic-dump.sh` at the end of its run, so you typically do not need to call it manually.

---

## Chain File Format

Each line in `integrity-chain.txt` has the format:
```
2026-01-01T05:30:00Z | /root/forensic-history/dumps/system-dump-2026-01-01.txt | <sha256hash>
```

---

## Append-Only Protection

On first run, `chattr +a` is applied to the chain file. After that:
- Appends are allowed
- Rewrites and deletions are blocked — even by root
- Only `chattr -a` (which requires explicit operator action) can disable this

> **Note:** `chattr +a` works on ext4. On ZFS or tmpfs it may silently fail. The script will warn but not exit if this happens.

---

## Idempotency

Running the script multiple times for the same dump is safe. If the dump file is already recorded in the chain, the script skips it and exits cleanly.

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/dumps/integrity-chain.txt` | The chain — never delete, never rewrite |
| `/root/forensic-history/dumps/system-dump-*.txt` | Forensic dumps referenced in the chain |
| `/root/forensic-history/dumps/.integrity.lock` | Lockfile preventing parallel writes |
| `/var/log/integrity-chain.log` | Cron output log |

---

## Install

```bash
cp update-integrity-chain.sh /usr/local/bin/
chmod +x /usr/local/bin/update-integrity-chain.sh
mkdir -p /root/forensic-history/dumps
```

Add to crontab on Proxmox (`crontab -e`):
```
30 5 1 1,4,7,10 *   /usr/local/bin/update-integrity-chain.sh >> /var/log/integrity-chain.log 2>&1
```

---

## Script

```bash
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
```
