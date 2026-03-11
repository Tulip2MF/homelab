#!/usr/bin/env bash
#
# predict-capacity.sh
#
# Runs on: Proxmox Host (192.168.178.127)
# Linear extrapolation of capacity growth across last 10 quarterly samples.
# Estimates how many samples remain before CRITICAL threshold is reached.

set -euo pipefail

source /root/forensic-config.sh

DIR="/root/forensic-history/metrics"
FILES=$(ls -t "$DIR"/metrics-* 2>/dev/null | head -10 | tac)
COUNT=$(echo "$FILES" | grep -c . || true)

if [ "$COUNT" -lt 5 ]; then
    echo "Insufficient data (need 5, have ${COUNT}). Collect quarterly metrics first."
    exit 0
fi

predict_exhaustion() {
    local LABEL="$1" METRIC_KEY="$2" CRIT_THRESHOLD="$3"
    local FIRST LAST FIRST_CAP LAST_CAP GROWTH RATE REMAIN EST

    FIRST=$(echo "$FILES" | head -1)
    LAST=$(echo "$FILES"  | tail -1)

    FIRST_CAP=$(grep "^${METRIC_KEY}=" "$FIRST" | cut -d= -f2)
    LAST_CAP=$(grep  "^${METRIC_KEY}=" "$LAST"  | cut -d= -f2)

    if ! [[ "$FIRST_CAP" =~ ^[0-9]+$ ]] || ! [[ "$LAST_CAP" =~ ^[0-9]+$ ]]; then
        echo "${LABEL}: no numeric data -- skipping"
        return
    fi

    GROWTH=$(( LAST_CAP - FIRST_CAP ))
    if [ "$GROWTH" -le 0 ]; then
        echo "${LABEL}: no growth detected (current=${LAST_CAP}%)"
        return
    fi

    RATE=$(awk "BEGIN { printf \"%.6f\", ${GROWTH}/${COUNT} }")
    REMAIN=$(( CRIT_THRESHOLD - LAST_CAP ))

    if [ "$REMAIN" -le 0 ]; then
        echo "${LABEL}: ALREADY AT OR BEYOND CRITICAL (${LAST_CAP}% >= ${CRIT_THRESHOLD}%)"
        return
    fi

    EST=$(awk "BEGIN { printf \"%d\", ${REMAIN}/${RATE} }")
    echo "${LABEL}: ${EST} quarterly samples to CRITICAL (${CRIT_THRESHOLD}%)"
    echo "${LABEL}: current=${LAST_CAP}%  growth=${RATE}%/sample  (${GROWTH}% over ${COUNT} samples)"
}

predict_exhaustion "rpool capacity"           "RPOOL_CAPACITY"     "$RPOOL_CRIT"
predict_exhaustion "NVMe container partition" "NVME_PARTITION_CAP" "$RPOOL_CRIT"

echo "Prediction complete."
