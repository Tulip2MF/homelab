# Immich — docker-compose

Photo and video backup application. Runs on the Shipyard (Debian) at `192.168.178.141:2283`.

**Host:** Shipyard (Debian) `192.168.178.141`
**Compose directory:** `/opt/stacks/immich/` (or wherever you keep your stacks)
**UI:** `http://192.168.178.141:2283`

---

## Stack Overview

| Container | Image | Role |
|---|---|---|
| `immich_server` | `ghcr.io/immich-app/immich-server` | Main application + API |
| `immich_machine_learning` | `ghcr.io/immich-app/immich-machine-learning` | Face recognition, CLIP search |
| `immich_postgres` | `ghcr.io/immich-app/postgres` (custom) | Database with pgvecto.rs + pgvectors |
| `immich_redis` | `docker.io/valkey/valkey:9` | Ephemeral cache — not backed up |

> ⚠️ **Custom postgres image:** `immich_postgres` uses a custom image with `pgvecto.rs` and `pgvectors` extensions pinned to specific versions. Never restore the Immich database into a stock postgres container. Always use the same custom image. See the [Immich backup and restore documentation](https://immich.app/docs/administration/backup-and-restore).

> ⚠️ **`immich_redis` is ephemeral:** The Valkey container has no persistent volume. Immich treats it as a cache and rebuilds it automatically on restart. `dump-databases.sh` intentionally skips it.

---

## Environment Variables

Copy the template below to `.env` in the compose directory and fill in your values.

> 🔴 **Remove `COMPOSE_PROJECT_NAME=paperless` if present.** This line was mistakenly included in early versions of this file and will cause all Immich container names to use the `paperless` prefix instead of `immich`. See `known-issues.md`.

```env
TZ=Europe/Berlin

# Absolute path to photo/video library on host
UPLOAD_LOCATION=/var/lib/docker/immich/library

# Absolute path to postgres data directory on host
# Must be on SSD -- not NAS, not NFS
DB_DATA_LOCATION=/var/lib/docker/immich/postgres

# Immich version (leave as 'release' to track latest stable)
IMMICH_VERSION=release

# Postgres credentials -- use a strong random password
DB_PASSWORD=CHANGE_ME
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
```

---

## Volumes and Data Paths

| Path on host | Container path | Purpose |
|---|---|---|
| `$UPLOAD_LOCATION` | `/data` | Photo and video library |
| `$DB_DATA_LOCATION` | `/var/lib/postgresql/data` | Postgres data directory |
| `model-cache` (Docker volume) | `/cache` | ML model cache |

The postgres data directory is also backed up as a raw filesystem copy by `dump-databases.sh` at `/mnt/truenas/db-dumps/immich-pgdata-YYYY-MM-DD/` as a supplementary safety layer alongside the `pg_dump` output.

---

## Backup Coverage

| What | How |
|---|---|
| Database | `dump-databases.sh` → `pg_dump` nightly → Harbour (TrueNAS) |
| Database raw | `dump-databases.sh` → rsync of bind-mount → Harbour (TrueNAS) |
| Photo/video library | Included in PBS VM backup → Harbour (TrueNAS) → Filen Cloud |
| Valkey cache | Not backed up — ephemeral by design |

---

## docker-compose.yml

```yaml
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION}:/data
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - '2283:2283'
    depends_on:
      - redis
      - database
    restart: always
    labels:
      - "diun.enable=true"
      - homepage.group=Media
      - homepage.id=immich
      - homepage.name=Immich
      - homepage.icon=immich
      - homepage.href=http://192.168.178.141:2283
      - homepage.description=Photo and Video Backup
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9@sha256:546304417feac0874c3dd576e0952c6bb8f06bb4093ea0c9ca303c73cf458f63
    healthcheck:
      test: redis-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf63357191b76a916ae5eb93464d65c07511da41e3bf7a8416db519b40b1c23
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    shm_size: 128mb
    restart: always
    healthcheck:
      disable: false

volumes:
  model-cache:
```
