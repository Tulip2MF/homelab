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
# Aligns with forensic-config.sh NVME_WARN/NVME_CRIT thresholds
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
