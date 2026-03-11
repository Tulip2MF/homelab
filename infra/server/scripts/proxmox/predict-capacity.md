# predict-capacity.sh

Linear extrapolation of capacity growth across the last 10 quarterly samples. Estimates how many quarters remain before each tracked metric reaches its critical threshold.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/predict-capacity.sh`
**Cron:** Called by `quarterly-report.sh` — no independent cron needed
**Classification:** Executor

---

## Purpose

Uses historical quarterly metrics to project when rpool and the NVMe container partition will reach their critical capacity thresholds. Gives you a forward-looking estimate so you can plan hardware additions before you're in an emergency.

Designed to be called by `quarterly-report.sh`, but can be run standalone after enough metrics history has accumulated.

Requires at least 5 historical quarterly samples to produce predictions. Before that it exits with a notice.

---

## Prediction Method

For each metric:
1. Take the oldest and newest values from the last 10 quarterly samples
2. Calculate total growth and average growth per sample
3. Calculate how many more samples at that rate until the critical threshold is reached
4. Output the estimate in quarters

The output is forward-looking and linear. It does not account for non-linear growth patterns.

---

## Metrics Predicted

| Metric | Critical threshold |
|---|---|
| rpool capacity | 85% (`RPOOL_CRIT`) |
| NVMe container partition | 85% (`RPOOL_CRIT`) |

---

## Output Examples

```
rpool capacity: 14 quarterly samples to CRITICAL (85%)
rpool capacity: current=42%  growth=0.8%/sample  (8% over 10 samples)

NVMe container partition: 7 quarterly samples to CRITICAL (85%)
NVMe container partition: current=61%  growth=2.4%/sample  (24% over 10 samples)
```

`quarterly-report.sh` flags metrics predicted to exhaust within 4 quarters (1 year) as critical and within 8 quarters (2 years) as a warning.

---

## Dependencies

- `forensic-config.sh` at `/root/forensic-config.sh`
- At least 5 metrics files in `/root/forensic-history/metrics/`

---

## Install

```bash
cp predict-capacity.sh /usr/local/bin/
chmod +x /usr/local/bin/predict-capacity.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# predict-capacity.sh
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)
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
```
