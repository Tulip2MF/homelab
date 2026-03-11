# Portainer — docker-compose

Docker management UI. Provides a web interface for managing containers, images, volumes, and stacks. Runs on the Shipyard (Debian).

**Host:** Shipyard (Debian) `192.168.178.141`
**Compose directory:** `/opt/stacks/portainer/`
**UI (HTTP):** `http://192.168.178.141:9000`
**UI (HTTPS):** `https://192.168.178.141:9443`

---

## Stack Overview

| Container | Image | Role |
|---|---|---|
| `portainer` | `portainer/portainer-ce:latest` | Docker management UI |

---

## Environment Variables

```env
PORTAINER_HTTP_PORT=9000
PORTAINER_HTTPS_PORT=9443
PORTAINER_DATA_PATH=/var/lib/docker/appdata/portainer
```

---

## Volumes

| Path on host | Container path | Purpose |
|---|---|---|
| `$PORTAINER_DATA_PATH` | `/data` | Portainer persistent data (users, settings, stacks) |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker socket — full read-write access |

The data directory is on the NVMe partition (`/var/lib/docker/appdata/portainer`). It is included in the PBS full-VM backup and does not require a separate export.

> Note: Portainer has full Docker socket access (read-write). It is a privileged management tool — do not expose its ports outside the local network.

---

## docker-compose.yml

```yaml
services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped

    ports:
      - "${PORTAINER_HTTP_PORT}:9000"
      - "${PORTAINER_HTTPS_PORT}:9443"

    volumes:
      - "${PORTAINER_DATA_PATH}:/data"
      - /var/run/docker.sock:/var/run/docker.sock

    labels:
      - homepage.group=Infrastructure
      - homepage.name=Portainer
      - homepage.icon=portainer
      - homepage.href=https://192.168.178.141:${PORTAINER_HTTPS_PORT}
```
