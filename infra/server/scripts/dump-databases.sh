#!/usr/bin/env bash
#
# dump-databases.sh
#
# ROLE:        executor
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Debian VM (192.168.178.141, hostname: shipyard)
#
# STACK:
#   paperless-db-1    postgres:18                         Paperless-NGX database
#   paperless-broker-1  redis:8                           Paperless-NGX broker
#   immich_postgres   immich custom postgres (pgvecto.rs) Immich database
#   immich_redis      valkey/valkey:9                     Immich cache
#   homepage          no database
#   portainer         no database
#
# All databases run INSIDE Docker containers -- no host-level postgres or redis.
# Dumps are taken via docker exec, not pg_dump on the host.
#
# IMMICH NOTE:
#   immich_postgres uses a custom image with pgvecto.rs and pgvectors extensions.
#   pg_dump output is compatible with stock postgres, but RESTORE requires the
#   same custom image. Never attempt to restore immich DB into a stock postgres.
#   The PBS full-VM backup is the safer restore path for Immich.
#   These dumps are for: individual table recovery, corruption diagnosis,
#   and off-site cloud coverage via rclone.
#
# DUMP DESTINATION:
#   Written to TrueNAS NFS mount so rclone picks them up on Sunday upload.
#   Path: /mnt/truenas/db-dumps/
#   Retention: 14 days of dumps kept on TrueNAS.
#
# Cron (Debian VM -- nightly at 02:00, before rclone window):
#   0 2 * * *   /usr/local/bin/dump-databases.sh >> /var/log/db-dumps.log 2>&1

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
    # Non-fatal: log and email but continue to next dump.
    # A single DB failure should not block all other dumps.
    echo "[DB-DUMP] FAIL: $1" | tee -a "$LOG" >&2
    echo "DB dump FAILED: $1" | mail -s "[HOMELAB DB DUMP FAIL] $1" root 2>/dev/null || true
    FAILURES=$(( FAILURES + 1 ))
}

fail_hard() {
    # Fatal: inhibit + abort. Used for infrastructure failures.
    echo "[DB-DUMP] HARD FAIL: $1" | tee -a "$LOG" >&2
    echo "DB dump HARD FAIL: $1" | mail -s "[HOMELAB DB DUMP FAIL] $1" root 2>/dev/null || true
    exit 1
}

echo "[DB-DUMP] Starting $(date --iso-8601=seconds)" | tee -a "$LOG"

# 1. Inhibit re-check
[ -f "$INHIBIT" ] && fail_hard "backup_inhibit present -- aborting"

# 2. NFS accessible
timeout 10 ls "$NFS_MOUNT" >/dev/null 2>&1 \
    || fail_hard "TrueNAS NFS ${NFS_MOUNT} unresponsive -- cannot write dumps"

# 3. Create dump directory (on NFS -- rclone will pick this up)
mkdir -p "$DUMP_DIR" || fail_hard "Cannot create dump directory ${DUMP_DIR}"

# ─── Helper: postgres dump via docker exec ────────────────────────────────────
# Usage: dump_postgres <container_name> <db_name> <output_label>
# Uses pg_dump in custom format (-Fc) for pg_restore compatibility.
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
# Triggers BGSAVE then copies the RDB file out.
dump_redis() {
    local CONTAINER="$1" LABEL="$2"
    local OUTFILE="${DUMP_DIR}/redis-${LABEL}-${DATE}.rdb"

    echo "[DB-DUMP] Redis: ${CONTAINER} -> ${OUTFILE}" | tee -a "$LOG"

    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
        fail_soft "Container ${CONTAINER} is not running -- skipping"
        return
    fi

    # Trigger background save
    docker exec "${CONTAINER}" redis-cli BGSAVE >/dev/null 2>&1 \
        || docker exec "${CONTAINER}" valkey-cli BGSAVE >/dev/null 2>&1 \
        || { fail_soft "BGSAVE failed for ${CONTAINER}"; return; }

    # Wait for save to complete (max 30s)
    local BEFORE AFTER
    BEFORE=$(docker exec "${CONTAINER}" sh -c 'redis-cli LASTSAVE 2>/dev/null || valkey-cli LASTSAVE 2>/dev/null' 2>/dev/null || echo 0)
    for i in $(seq 1 30); do
        sleep 1
        AFTER=$(docker exec "${CONTAINER}" sh -c 'redis-cli LASTSAVE 2>/dev/null || valkey-cli LASTSAVE 2>/dev/null' 2>/dev/null || echo 0)
        [ "$AFTER" != "$BEFORE" ] && break
    done

    # Copy RDB out of container
    # Standard redis/valkey RDB path is /data/dump.rdb
    docker cp "${CONTAINER}:/data/dump.rdb" "${OUTFILE}" 2>>"$LOG" \
        || { fail_soft "docker cp RDB failed for ${CONTAINER}"; return; }

    local SIZE
    SIZE=$(du -sh "${OUTFILE}" 2>/dev/null | cut -f1)
    echo "[DB-DUMP] OK: ${LABEL} (${SIZE})" | tee -a "$LOG"
}

# ─── Paperless-NGX ───────────────────────────────────────────────────────────
# Postgres: container=paperless-db-1, db=paperless (default paperless DB name)
# Redis:    container=paperless-broker-1
dump_postgres "paperless-db-1"    "paperless" "paperless"
dump_redis    "paperless-broker-1"             "paperless"

# ─── Immich ───────────────────────────────────────────────────────────────────
# Postgres: container=immich_postgres
#   Bind mount: /var/lib/docker/immich/postgres -> /var/lib/postgresql/data
#   RESTORE WARNING: requires ghcr.io/immich-app/postgres image (pgvecto.rs extensions).
#   Never restore into stock postgres. Use immich docs restore procedure:
#   https://immich.app/docs/administration/backup-and-restore
#
# Redis/Valkey: container=immich_redis
#   NO VOLUME -- immich_redis has no persistent mount (confirmed via docker inspect).
#   Valkey is used as an ephemeral cache only. Nothing to back up.
#   Loss of immich_redis on restart is expected and handled by Immich automatically.
dump_postgres "immich_postgres" "immich" "immich"
# immich_redis intentionally skipped -- ephemeral cache, no volume, nothing to dump

# ─── Immich Postgres bind-mount filesystem copy (extra safety layer) ───────────
# immich_postgres uses a bind mount at /var/lib/docker/immich/postgres.
# In addition to the pg_dump above, copy the raw data directory.
# This gives a second recovery path if pg_dump output is unusable.
# NOTE: this is NOT a consistent snapshot -- pg_dump above is the trusted backup.
#       This copy is supplementary only.
IMMICH_PG_SRC="/var/lib/docker/immich/postgres"
IMMICH_PG_DEST="${DUMP_DIR}/immich-pgdata-${DATE}"
if [ -d "$IMMICH_PG_SRC" ]; then
    echo "[DB-DUMP] Copying Immich Postgres bind-mount data dir..." | tee -a "$LOG"
    # Stop briefly for consistency? No -- pg_dump above is the consistent backup.
    # This is a best-effort filesystem copy only.
    rsync -a --delete "$IMMICH_PG_SRC/" "$IMMICH_PG_DEST/" 2>>"$LOG" \
        && echo "[DB-DUMP] OK: immich pgdata dir copied to ${IMMICH_PG_DEST}" | tee -a "$LOG" \
        || fail_soft "rsync of immich pgdata dir failed"
    # Rotate old pgdata copies
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
