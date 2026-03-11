# forensic-config.sh

Single source of truth for all operational thresholds used by the Proxmox forensic and analytics scripts. Sourced by `score-metrics.sh`, `predict-capacity.sh`, and `anomaly-detection.sh`.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/root/forensic-config.sh`
**Cron:** None — sourced by other scripts
**Classification:** Config

---

## Purpose

Centralises every threshold used in quarterly risk scoring and anomaly detection. Changing a value here automatically updates all three consumer scripts. Never edit thresholds in individual scripts — always edit here.

---

## Thresholds Reference

| Variable | Default | Meaning |
|---|---|---|
| `RPOOL_WARN` | 75% | ZFS rpool capacity — warn level |
| `RPOOL_CRIT` | 85% | ZFS rpool capacity — critical level |
| `FRAG_WARN` | 40% | ZFS rpool fragmentation — warn level |
| `FRAG_CRIT` | 60% | ZFS rpool fragmentation — critical level |
| `NVME_WARN` | 70% | NVMe percentage_used (wear) — 30% life remaining |
| `NVME_CRIT` | 85% | NVMe percentage_used (wear) — 15% life remaining |
| `AWAIT_WARN` | 10ms | NVMe IO latency — warn level |
| `AWAIT_CRIT` | 25ms | NVMe IO latency — critical level |
| `RAM_WARN` | 80% | RAM usage — warn level |
| `RAM_CRIT` | 90% | RAM usage — critical level |
| `ALERT_EMAIL` | root | Email address for all alerts |

---

## NVMe Wear Note

The Samsung 990 PRO reports `percentage_used` as a direct wear indicator — 0% means new, 100% means the rated TBW is exhausted. The `NVME_WARN=70` threshold means "70% of rated life consumed, 30% remaining". This is the correct reading — do not invert this value.

The 2TB Samsung 990 PRO is rated at 1200 TBW.

---

## Network Reference

```
Main Server — Proxmox  192.168.178.127  (THIS HOST)
Harbour (TrueNAS)    192.168.178.139
Drydock (PBS — Proxmox)   192.168.178.142
Shipyard (Debian)     192.168.178.141
```

---

## Install

```bash
cp forensic-config.sh /root/
chmod 600 /root/forensic-config.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# forensic-config.sh
#
# Single source of truth for all operational thresholds.
# Sourced by: score-metrics.sh, predict-capacity.sh, anomaly-detection.sh
#
# Network reference:
#   Main Server — Proxmox  192.168.178.127
#   Harbour (TrueNAS)    192.168.178.139
#   Drydock (PBS — Proxmox)   192.168.178.142
#   Shipyard (Debian)     192.168.178.141

# ZFS rpool capacity (%)
RPOOL_WARN=75
RPOOL_CRIT=85

# ZFS fragmentation (%)
FRAG_WARN=40
FRAG_CRIT=60

# NVMe wear -- Samsung 990 PRO percentage_used (direct, no inversion)
# 70% used = 30% life remaining = WARN
# 85% used = 15% life remaining = CRIT
NVME_WARN=70
NVME_CRIT=85

# NVMe IO latency (ms)
AWAIT_WARN=10
AWAIT_CRIT=25

# RAM usage (system has 48GB -- one DIMM removed/failed)
RAM_WARN=80
RAM_CRIT=90

ALERT_EMAIL="root"
```
