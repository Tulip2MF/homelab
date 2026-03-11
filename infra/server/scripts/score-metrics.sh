#!/usr/bin/env bash
#
# score-metrics.sh
#
# Runs on: Proxmox Host (192.168.178.127)
# Deterministic risk scoring against latest metrics file.
# Emails on HIGH or CRITICAL risk level.
#
# Run manually or after collect-metrics.sh:
#   /usr/local/bin/score-metrics.sh

set -euo pipefail

source /root/forensic-config.sh

DIR="/root/forensic-history/metrics"
LATEST=$(ls -t "$DIR"/metrics-* 2>/dev/null | head -1)
[ -z "$LATEST" ] && { echo "No metrics files found in ${DIR}."; exit 1; }

SCORE=0

RPOOL=$(grep    "^RPOOL_CAPACITY="     "$LATEST" | cut -d= -f2)
FRAG=$(grep     "^RPOOL_FRAGMENTATION=" "$LATEST" | cut -d= -f2)
AWAIT=$(grep    "^NVME_AWAIT_MS="      "$LATEST" | cut -d= -f2)
RAM=$(grep      "^RAM_USED_PCT="       "$LATEST" | cut -d= -f2)
NVME_PART=$(grep "^NVME_PARTITION_CAP=" "$LATEST" | cut -d= -f2)

score_metric() {
    local VAL="$1" WARN="$2" CRIT="$3"
    [[ "$VAL" =~ ^[0-9]+$ ]] || return 0
    if [ "$VAL" -ge "$CRIT" ]; then SCORE=$(( SCORE + 3 )); return; fi
    if [ "$VAL" -ge "$WARN" ]; then SCORE=$(( SCORE + 1 )); fi
}

score_metric "$RPOOL"     "$RPOOL_WARN"  "$RPOOL_CRIT"
score_metric "$FRAG"      "$FRAG_WARN"   "$FRAG_CRIT"
score_metric "$AWAIT"     "$AWAIT_WARN"  "$AWAIT_CRIT"
score_metric "$RAM"       "$RAM_WARN"    "$RAM_CRIT"
score_metric "$NVME_PART" "$RPOOL_WARN"  "$RPOOL_CRIT"

# NVMe wear per drive -- only lines like NVME_nvme0n1_USED (not AWAIT, not PARTITION)
while IFS='=' read -r KEY VAL; do
    score_metric "$VAL" "$NVME_WARN" "$NVME_CRIT"
done < <(grep -E '^NVME_nvme[0-9]+n[0-9]+_USED=' "$LATEST")

if   [ "$SCORE" -ge 5 ]; then LEVEL="CRITICAL"
elif [ "$SCORE" -ge 3 ]; then LEVEL="HIGH"
elif [ "$SCORE" -ge 1 ]; then LEVEL="MEDIUM"
else                          LEVEL="LOW"
fi

echo "RISK_LEVEL=${LEVEL}"
echo "RISK_SCORE=${SCORE}"
echo "Metrics file: ${LATEST}"

if [ "$LEVEL" = "HIGH" ] || [ "$LEVEL" = "CRITICAL" ]; then
    {
        echo "Risk level : ${LEVEL}"
        echo "Risk score : ${SCORE}"
        echo "Metrics    : ${LATEST}"
        echo ""
        echo "rpool=${RPOOL}%  frag=${FRAG}%  await=${AWAIT}ms  ram=${RAM}%  nvme_partition=${NVME_PART}%"
    } | mail -s "[HOMELAB RISK ${LEVEL}] Score ${SCORE} on $(date +%F)" root 2>/dev/null || true
fi
