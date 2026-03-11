# collect-metrics.sh

Collects numeric health indicators from the Proxmox host into a timestamped metrics file. Used as input for quarterly risk scoring, anomaly detection, and capacity prediction.

**Host:** Proxmox Host `192.168.178.127`
**Install path:** `/usr/local/bin/collect-metrics.sh`
**Cron:** `0 6 1 1,4,7,10 *   /usr/local/bin/collect-metrics.sh`
**Classification:** Executor

---

## Purpose

Runs quarterly (1st of January, April, July, October) and writes a snapshot of key system metrics to a dated file in `/root/forensic-history/metrics/`. These files build up over time as a historical record that `score-metrics.sh`, `anomaly-detection.sh`, and `predict-capacity.sh` read to detect drift and project capacity exhaustion.

Must be run before `score-metrics.sh`, `anomaly-detection.sh`, and `quarterly-report.sh` on the same day.

---

## Metrics Collected

| Metric key | Source | Description |
|---|---|---|
| `RPOOL_CAPACITY` | `zpool list` | ZFS rpool used capacity % |
| `RPOOL_FRAGMENTATION` | `zpool list` | ZFS rpool fragmentation % |
| `NVME_nvme0n1_USED` | `nvme smart-log` | NVMe wear — percentage_used (direct) |
| `NVME_AWAIT_MS` | `iostat` | NVMe IO latency in ms |
| `NVME_PARTITION_CAP` | `df` | `/var/lib/docker` partition usage % |
| `RAM_TOTAL_MB` | `free` | Total RAM in MB (expected ~48000 with one DIMM removed) |
| `RAM_USED_MB` | `free` | Used RAM in MB |
| `RAM_USED_PCT` | calculated | RAM usage percentage |

---

## Output

Files are written to `/root/forensic-history/metrics/metrics-YYYY-MM-DD_HHMMSS.txt`.

Example output:
```
DATE=2026-01-01
TIMESTAMP=2026-01-01_060000
RPOOL_CAPACITY=34
RPOOL_FRAGMENTATION=12
NVME_nvme0n1_USED=4
NVME_AWAIT_MS=1
NVME_PARTITION_CAP=47
RAM_TOTAL_MB=48432
RAM_USED_MB=12841
RAM_USED_PCT=26
```

---

## Quarterly Cron Sequence (all on Proxmox)

The four quarterly scripts must run in order on the same day. Suggested cron schedule:

```
0 5 1 1,4,7,10 *   /usr/local/bin/forensic-dump.sh
0 6 1 1,4,7,10 *   /usr/local/bin/collect-metrics.sh
30 5 1 1,4,7,10 *  /usr/local/bin/update-integrity-chain.sh
0 7 1 1,4,7,10 *   /usr/local/bin/anomaly-detection.sh
0 8 1 1,4,7,10 *   /usr/local/bin/quarterly-report.sh
```

`score-metrics.sh` and `predict-capacity.sh` are called by `quarterly-report.sh` and do not need their own cron entries.

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/metrics/` | Directory where metrics files are written |
| `/root/forensic-config.sh` | Not sourced by this script — thresholds are in consumer scripts |

---

## Dependencies

- `nvme-cli`: `apt install nvme-cli`
- `sysstat` (for `iostat`): `apt install sysstat`
- `zpool` available (included in Proxmox)

---

## Install

```bash
cp collect-metrics.sh /usr/local/bin/
chmod +x /usr/local/bin/collect-metrics.sh
mkdir -p /root/forensic-history/metrics
```

Add to crontab on Proxmox (`crontab -e`):
```
0 6 1 1,4,7,10 *   /usr/local/bin/collect-metrics.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# collect-metrics.sh
#
# Runs on: Proxmox Host (192.168.178.127)
# Collects numeric health indicators for scoring and anomaly detection.
# Timestamped filename -- safe to run multiple times on the same day.
#
# Cron (Proxmox host -- quarterly):
#   0 6 1 1,4,7,10 *   /usr/local/bin/collect-metrics.sh

set -euo pipefail

DATE=$(date +%F_%H%M%S)
OUT="/root/forensic-history/metrics/metrics-${DATE}.txt"

mkdir -p "$(dirname "$OUT")"

{
echo "DATE=$(date +%F)"
echo "TIMESTAMP=${DATE}"

# ZFS rpool capacity
RPOOL_CAP=$(zpool list -H -o capacity rpool | tr -d '%')
echo "RPOOL_CAPACITY=${RPOOL_CAP}"

# ZFS fragmentation
FRAG=$(zpool list -H -o fragmentation rpool | tr -d '%')
echo "RPOOL_FRAGMENTATION=${FRAG}"

# NVMe wear -- percentage_used directly (no inversion)
for drive in /dev/nvme[0-9]n1; do
    if [ -e "$drive" ]; then
        PUSED=$(nvme smart-log "$drive" 2>/dev/null | awk '/percentage_used/ {print $3}')
        echo "NVME_${drive##*/}_USED=${PUSED}"
    fi
done

# NVMe IO latency
if command -v iostat >/dev/null 2>&1; then
    AWAIT=$(iostat -xy 1 2 2>/dev/null | awk '/nvme/ {print $10}' | tail -1)
    if [[ "$AWAIT" =~ ^[0-9.]+$ ]]; then
        AWAIT_ROUNDED=$(printf "%.0f" "$AWAIT")
        echo "NVME_AWAIT_MS=${AWAIT_ROUNDED}"
    fi
fi

# NVMe container partition capacity
NVME_PART_MOUNT="/var/lib/docker"
if mountpoint -q "$NVME_PART_MOUNT" 2>/dev/null; then
    NVME_PART_CAP=$(df -P "$NVME_PART_MOUNT" 2>/dev/null \
        | awk 'NR==2 {gsub(/%/,"",$5); print int($5)}')
    echo "NVME_PARTITION_CAP=${NVME_PART_CAP}"
else
    echo "NVME_PARTITION_CAP=UNAVAILABLE"
fi

# RAM metrics -- 48GB system (one DIMM removed)
RAM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
RAM_USED=$(free -m  | awk '/^Mem:/ {print $3}')
if [[ "$RAM_TOTAL" =~ ^[0-9]+$ ]] && [ "$RAM_TOTAL" -gt 0 ]; then
    RAM_PCT=$(awk "BEGIN {printf \"%d\", (${RAM_USED}/${RAM_TOTAL})*100}")
    echo "RAM_TOTAL_MB=${RAM_TOTAL}"
    echo "RAM_USED_MB=${RAM_USED}"
    echo "RAM_USED_PCT=${RAM_PCT}"
fi

} > "$OUT"

echo "Metrics written to ${OUT}"
```
