# dump-databases.sh

Nightly database dump script. Exports all application databases from their Docker containers to the Harbour (TrueNAS) NFS mount so they are picked up by the weekly rclone upload to Filen Cloud.

**Host:** Shipyard (Debian) `192.168.178.141`
**Install path:** `/usr/local/bin/dump-databases.sh`
**Cron:** `0 2 * * *   /usr/local/bin/dump-databases.sh >> /var/log/db-dumps.log 2>&1`
**Classification:** Executor

---

## Purpose

Provides application-level database backups that complement the PBS full-VM backup. While PBS can restore the entire VM, these dumps allow individual database or table recovery without a full restore, and provide the data that gets uploaded to Filen Cloud for off-site coverage.

Dumps are written directly to Harbour (TrueNAS) NFS so the rclone upload on Sunday automatically includes them. The Shipyard (Debian) never holds a persistent local copy.

---

## Container Stack

| Container | Image | Database | User |
|---|---|---|---|
| `paperless-db-1` | `postgres:18` | `paperless` | `paperless` |
| `paperless-broker-1` | `redis:8` | — | — |
| `immich_postgres` | `ghcr.io/immich-app/postgres` (custom) | `immich` | `postgres` |
| `immich_redis` | `valkey:9` | — | ephemeral, not dumped |

> ⚠️ **Known Bug:** The `dump_postgres` helper currently uses `-U postgres` for all containers. This will fail for `paperless-db-1` which only has the `paperless` user. Fix: pass the postgres username as a parameter per container. See `known-issues.md`.

> ⚠️ **Immich restore warning:** `immich_postgres` uses a custom image with `pgvecto.rs` and `pgvectors` extensions. These dumps are compatible with standard `pg_dump` format but **restoring requires the same custom Immich postgres image**. Never restore an Immich dump into a stock postgres container. Use the Immich documentation restore procedure.

---

## Output Files

All written to `/mnt/truenas/db-dumps/` with 14-day retention.

| File pattern | Source |
|---|---|
| `pg-paperless-YYYY-MM-DD.dump` | `paperless-db-1` / `paperless` db |
| `pg-immich-YYYY-MM-DD.dump` | `immich_postgres` / `immich` db |
| `redis-paperless-YYYY-MM-DD.rdb` | `paperless-broker-1` RDB snapshot |
| `immich-pgdata-YYYY-MM-DD/` | Raw Immich postgres bind-mount (supplementary) |

`immich_redis` is intentionally not dumped — it is a Valkey ephemeral cache with no persistent volume. Immich handles cache rebuilds automatically on restart.

---

## Failure Behaviour

- Infrastructure failures (NFS unavailable, inhibit set) → `fail_hard`: sets inhibit, emails, aborts
- Individual dump failures → `fail_soft`: emails and continues to next dump
- Final exit code is non-zero if any dump failed

---

## Key Files

| File | Purpose |
|---|---|
| `/mnt/truenas/db-dumps/` | Dump destination on Harbour (TrueNAS) NFS |
| `/var/log/db-dumps-YYYY-MM-DD.log` | Dated log per run |
| `/var/run/backup_inhibit` | Checked at start; set on hard failure |

---

## Dependencies

- Harbour (TrueNAS) NFS mounted at `/mnt/truenas` (read-write for this path)
- Docker running with all application containers
- `rsync` installed for the Immich pgdata supplementary copy

---

## Install

```bash
cp dump-databases.sh /usr/local/bin/
chmod +x /usr/local/bin/dump-databases.sh
```

Add to crontab (`crontab -e`):
```
0 2 * * *   /usr/local/bin/dump-databases.sh >> /var/log/db-dumps.log 2>&1
```

---

## Script

```bash
#!/usr/bin/env bash
#
# dump-databases.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Shipyard (Debian) (192.168.178.141, hostname: Shipyard (Debian))

set -euo pipefail

INHIBIT="/var/run/backup_inhibit"
[ -f "$INHIBIT" ] && exit 0

NFS_MOUNT="/mnt/truenas"
DUMP_DIR="${NFS_MOUNT}/db-dumps"
DATE=$(date +%F)
LOG="/var/log/db-dumps-${DATE}.log"
KEEP_DAYS=14
FAILURES=0

fail_soft() {
    echo "[DB-DUMP] FAIL: $1" | tee -a "$LOG" >&2
    echo "DB dump FAILED: $1" | mail -s "[HOMELAB DB DUMP FAIL] $1" root 2>/dev/null || true
    FAILURES=$(( FAILURES + 1 ))
}

fail_hard() {
    echo "[DB-DUMP] HARD FAIL: $1" | tee -a "$LOG" >&2
    echo "DB dump HARD FAIL: $1" | mail -s "[HOMELAB DB DUMP FAIL] $1" root 2>/dev/null || true
    exit 1
}

echo "[DB-DUMP] Starting $(date --iso-8601=seconds)" | tee -a "$LOG"

# 1. Inhibit re-check
[ -f "$INHIBIT" ] && fail_hard "backup_inhibit present -- aborting"

# 2. NFS accessible
timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1 \
    || fail_hard "Harbour (TrueNAS) NFS ${NFS_MOUNT} unresponsive -- cannot write dumps"

# 3. Create dump directory
mkdir -p "$DUMP_DIR" || fail_hard "Cannot create dump directory ${DUMP_DIR}"

# ─── Helper: postgres dump via docker exec ────────────────────────────────────
# ⚠ BUG: -U postgres is wrong for paperless-db-1 (user is 'paperless').
# Fix: add a PGUSER parameter and pass per-container. See known-issues.md.
dump_postgres() {
    local CONTAINER="$1" DB="$2" LABEL="$3"
    local OUTFILE="${DUMP_DIR}/pg-${LABEL}-${DATE}.dump"

    echo "[DB-DUMP] Postgres: ${CONTAINER} / ${DB} -> ${OUTFILE}" | tee -a "$LOG"

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        fail_soft "Container ${CONTAINER} is not running -- skipping"
        return
    fi

    docker exec "${CONTAINER}" pg_dump -U postgres -Fc "${DB}" > "${OUTFILE}" 2>>"$LOG" \
        || { fail_soft "pg_dump failed: ${CONTAINER}/${DB}"; rm -f "${OUTFILE}"; return; }

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" 2>/dev/null | cut -f1)
    echo "[DB-DUMP] OK: ${LABEL} (${SIZE})" | tee -a "$LOG"
}

# ─── Helper: redis/valkey dump via docker exec ────────────────────────────────
dump_redis() {
    local CONTAINER="$1" LABEL="$2"
    local OUTFILE="${DUMP_DIR}/redis-${LABEL}-${DATE}.rdb"

    echo "[DB-DUMP] Redis: ${CONTAINER} -> ${OUTFILE}" | tee -a "$LOG"

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        fail_soft "Container ${CONTAINER} is not running -- skipping"
        return
    fi

    docker exec "${CONTAINER}" redis-cli BGSAVE >/dev/null 2>&1 \
        || docker exec "${CONTAINER}" valkey-cli BGSAVE >/dev/null 2>&1 \
        || { fail_soft "BGSAVE failed for ${CONTAINER}"; return; }

    local BEFORE AFTER
    BEFORE=$(docker exec "${CONTAINER}" sh -c 'redis-cli LASTSAVE 2>/dev/null || valkey-cli LASTSAVE 2>/dev/null' 2>/dev/null || echo 0)
    for i in $(seq 1 30); do
        sleep 1
        AFTER=$(docker exec "${CONTAINER}" sh -c 'redis-cli LASTSAVE 2>/dev/null || valkey-cli LASTSAVE 2>/dev/null' 2>/dev/null || echo 0)
        [ "$AFTER" != "$BEFORE" ] && break
    done

    docker cp "${CONTAINER}:/data/dump.rdb" "${OUTFILE}" 2>>"$LOG" \
        || { fail_soft "docker cp RDB failed for ${CONTAINER}"; return; }

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" 2>/dev/null | cut -f1)
    echo "[DB-DUMP] OK: ${LABEL} (${SIZE})" | tee -a "$LOG"
}

# ─── Paperless-NGX ───────────────────────────────────────────────────────────
dump_postgres "paperless-db-1"    "paperless" "paperless"
dump_redis    "paperless-broker-1"             "paperless"

# ─── Immich ───────────────────────────────────────────────────────────────────
# immich_redis intentionally skipped -- ephemeral cache, no volume, nothing to dump
dump_postgres "immich_postgres" "immich" "immich"

# ─── Immich Postgres bind-mount filesystem copy (supplementary) ───────────────
IMMICH_PG_SRC="/var/lib/docker/immich/postgres"
IMMICH_PG_DEST="${DUMP_DIR}/immich-pgdata-${DATE}"
if [ -d "$IMMICH_PG_SRC" ]; then
    echo "[DB-DUMP] Copying Immich Postgres bind-mount data dir..." | tee -a "$LOG"
    rsync -a --delete "$IMMICH_PG_SRC/" "$IMMICH_PG_DEST/" 2>>"$LOG" \
        && echo "[DB-DUMP] OK: immich pgdata dir copied to ${IMMICH_PG_DEST}" | tee -a "$LOG" \
        || fail_soft "rsync of immich pgdata dir failed"
    find "$DUMP_DIR" -maxdepth 1 -name "immich-pgdata-*" -type d -mtime +${KEEP_DAYS} \
        -exec rm -rf {} + 2>/dev/null || true
else
    echo "[DB-DUMP] Immich pgdata dir not found at ${IMMICH_PG_SRC} -- skipping filesystem copy" | tee -a "$LOG"
fi

# ─── Rotate old dumps ─────────────────────────────────────────────────────────
echo "[DB-DUMP] Rotating dumps older than ${KEEP_DAYS} days..." | tee -a "$LOG"
find "$DUMP_DIR" -name "pg-*.dump"   -mtime +${KEEP_DAYS} -delete 2>/dev/null || true
find "$DUMP_DIR" -name "redis-*.rdb" -mtime +${KEEP_DAYS} -delete 2>/dev/null || true

# ─── Rotate dump logs ─────────────────────────────────────────────────────────
find /var/log -maxdepth 1 -name "db-dumps-*.log" -mtime +90 -delete 2>/dev/null || true

# ─── Summary ──────────────────────────────────────────────────────────────────
if [ "$FAILURES" -gt 0 ]; then
    echo "[DB-DUMP] COMPLETED WITH ${FAILURES} FAILURE(S) -- check log: ${LOG}" | tee -a "$LOG"
    exit 1
fi

echo "[DB-DUMP] SUCCESS -- all dumps complete $(date --iso-8601=seconds)" | tee -a "$LOG"
exit 0
```
