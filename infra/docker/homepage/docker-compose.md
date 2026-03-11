# Homepage — docker-compose

Dashboard for the homelab. Shows the status of all services and links to their UIs. Runs on the Debian VM at `192.168.178.141:3000`.

**Host:** Debian VM `192.168.178.141`
**Compose directory:** `/opt/stacks/homepage/`
**UI:** `http://192.168.178.141:3000`

---

## Stack Overview

| Container | Image | Role |
|---|---|---|
| `homepage` | `ghcr.io/gethomepage/homepage` | Dashboard |

---

## Environment Variables

```env
TZ=Europe/Berlin
HOMEPAGE_ALLOWED_HOSTS=192.168.178.141:3000,homepage.local
```

---

## Volumes

| Path on host | Container path | Purpose |
|---|---|---|
| `/mnt/truenas/appdata/homepage/config` | `/app/config` | Homepage config files — stored on TrueNAS NFS |
| `/var/run/docker.sock` (read-only) | `/var/run/docker.sock` | Allows Homepage to read Docker container status |

The config is stored on TrueNAS NFS so it is included in the PBS backup chain and survives a Debian VM rebuild without any manual config export.

---

## User and Permissions

The container runs as `uid=2001 gid=3000` to match the permissions set on the TrueNAS NFS export. The additional group `989` is added for Docker socket access. Adjust these values if your TrueNAS user/group IDs differ.

---

## Service Labels

Other containers in the stack use `homepage.*` labels to register themselves automatically with the Homepage dashboard. Example from the Immich compose:

```yaml
labels:
  - homepage.group=Media
  - homepage.id=immich
  - homepage.name=Immich
  - homepage.icon=immich
  - homepage.href=http://192.168.178.141:2283
  - homepage.description=Photo and Video Backup
```

---

## docker-compose.yml

```yaml
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:latest
    container_name: homepage
    restart: unless-stopped

    # Run as non-root, mapped to your TrueNAS permissions
    user: "2001:3000"
    group_add:
      - "989"

    ports:
      - "3000:3000"

    env_file:
      - .env

    volumes:
      # TrueNAS-backed persistent config (REQUIRED)
      - /mnt/truenas/appdata/homepage/config:/app/config

      # Docker socket (read-only)
      - /var/run/docker.sock:/var/run/docker.sock:ro

    security_opt:
      - no-new-privileges:true
```
