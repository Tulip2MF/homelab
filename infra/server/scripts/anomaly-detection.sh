#!/usr/bin/env bash
#
# anomaly-detection.sh
#
# Runs on: Proxmox Host (192.168.178.127)
# Rolling mean anomaly detection over last 5 quarterly samples.
# Emails when any metric jumps significantly above its recent baseline.
#
# Cron (Proxmox host -- quarterly, after collect-metrics.sh):
#   0 7 1 1,4,7,10 *   /usr/local/bin/anomaly-detection.sh

set -euo pipefail

source /root/forensic-config.sh

DIR="/root/forensic-history/metrics"
LOG="/var/log/anomaly-detection-$(date +%Y%m%d).log"
ANOMALIES=0

FILES=$(ls -t "$DIR"/metrics-* 2>/dev/null | head -6)
COUNT=$(echo "$FILES" | grep -c . || true)

if [ "$COUNT" -lt 5 ]; then
    echo "Insufficient data (need 5 samples, have ${COUNT}). Run collect-metrics.sh quarterly." | tee -a "$LOG"
    exit 0
fi

LATEST=$(echo "$FILES" | head -1)
BASELINE=$(echo "$FILES" | tail -5)

flag() {
    echo "ANOMALY: $1" | tee -a "$LOG"
    ANOMALIES=$(( ANOMALIES + 1 ))
}

check_anomaly() {
    local LABEL="$1" KEY="$2" THRESHOLD="$3"
    local LATEST_VAL AVG DELTA

    LATEST_VAL=$(grep "^${KEY}=" "$LATEST" | cut -d= -f2)
    [[ "$LATEST_VAL" =~ ^[0-9]+$ ]] || { echo "${LABEL}: no numeric data -- skipping" | tee -a "$LOG"; return; }

    AVG=$(grep "^${KEY}=" $BASELINE | cut -d= -f2 \
        | grep -E '^[0-9]+$' \
        | awk '{sum+=$1} END {if(NR>0) print int(sum/NR); else print 0}')

    DELTA=$(( LATEST_VAL - AVG ))
    echo "${LABEL}: current=${LATEST_VAL}%  mean=${AVG}%  delta=+${DELTA}%" | tee -a "$LOG"

    if [ "$DELTA" -ge "$THRESHOLD" ]; then
        flag "${LABEL}: +${DELTA}% above 5-sample mean (threshold=${THRESHOLD}%)"
    fi
}

echo "=== Anomaly Detection $(date --iso-8601=seconds) ===" | tee -a "$LOG"
echo "Latest: ${LATEST}" | tee -a "$LOG"
echo "" | tee -a "$LOG"

check_anomaly "rpool capacity"           "RPOOL_CAPACITY"      5
check_anomaly "rpool fragmentation"      "RPOOL_FRAGMENTATION" 10
check_anomaly "NVMe container partition" "NVME_PARTITION_CAP"  5
check_anomaly "RAM pressure"             "RAM_USED_PCT"        10

echo "" | tee -a "$LOG"
echo "Anomaly check complete. Found: ${ANOMALIES}" | tee -a "$LOG"

if [ "$ANOMALIES" -gt 0 ]; then
    mail -s "[HOMELAB ANOMALY] ${ANOMALIES} metric(s) spiked on $(date +%F)" root < "$LOG" 2>/dev/null || true
fi

# Rotate logs older than 90 days
find /var/log -maxdepth 1 -name "anomaly-detection-*.log" -mtime +90 -delete 2>/dev/null || true
