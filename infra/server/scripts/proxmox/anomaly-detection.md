# anomaly-detection.sh

Rolling mean anomaly detection over the last 5 quarterly metrics samples. Flags any metric that has jumped significantly above its recent baseline and sends an email alert.

**Host:** Proxmox Host `192.168.178.127`
**Install path:** `/usr/local/bin/anomaly-detection.sh`
**Cron:** `0 7 1 1,4,7,10 *   /usr/local/bin/anomaly-detection.sh`
**Classification:** Executor

---

## Purpose

Where `score-metrics.sh` checks whether a metric exceeds an absolute threshold, `anomaly-detection.sh` checks whether a metric has made an unusual *jump* compared to its own recent history. This catches gradual trends that haven't yet hit a threshold but are accelerating unexpectedly.

For example, if rpool capacity has been at 30% for a year and suddenly jumps to 40% in one quarter, the absolute threshold check passes — but the anomaly check flags it as a 10-point jump above the 5-sample mean.

Requires at least 5 historical quarterly samples. Until then it exits with a notice and does nothing.

---

## Detection Method

For each metric:
1. Take the last 5 samples from the metrics history
2. Calculate the rolling mean of those 5 samples
3. Compare the most recent value to that mean
4. If the delta exceeds the threshold for that metric, flag as anomaly

---

## Anomaly Thresholds

| Metric | Delta threshold | Meaning |
|---|---|---|
| rpool capacity | +5% | Unusually large quarter-over-quarter growth |
| rpool fragmentation | +10% | Sharp fragmentation increase |
| NVMe container partition | +5% | Unusual capacity jump |
| RAM pressure | +10% | Significant increase in memory pressure |

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/metrics/` | Historical metrics files — needs ≥5 to function |
| `/var/log/anomaly-detection-YYYYMMDD.log` | Dated log per run — rotated after 90 days |

---

## Dependencies

- `forensic-config.sh` at `/root/forensic-config.sh`
- At least 5 metrics files in `/root/forensic-history/metrics/`

---

## Install

```bash
cp anomaly-detection.sh /usr/local/bin/
chmod +x /usr/local/bin/anomaly-detection.sh
```

Add to crontab on Proxmox (`crontab -e`):
```
0 7 1 1,4,7,10 *   /usr/local/bin/anomaly-detection.sh
```

---

## Script

```bash
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
```
