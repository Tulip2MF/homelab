# score-metrics.sh

Deterministic risk scoring against the latest quarterly metrics file. Assigns a risk level of LOW, MEDIUM, HIGH, or CRITICAL based on how many metrics are above their warn and critical thresholds.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/score-metrics.sh`
**Cron:** Called by `quarterly-report.sh` — no independent cron needed
**Classification:** Executor

---

## Purpose

Takes the most recent file from `/root/forensic-history/metrics/` and scores each metric against the thresholds defined in `forensic-config.sh`. Produces a risk level and emails if the level is HIGH or CRITICAL.

Designed to be called directly by `quarterly-report.sh`, but can also be run standalone after `collect-metrics.sh` has produced a new metrics file.

---

## Scoring Logic

Each metric contributes to a cumulative score:
- Metric at or above **critical** threshold: **+3 points**
- Metric at or above **warn** threshold: **+1 point**

| Total score | Risk level |
|---|---|
| 0 | LOW |
| 1–2 | MEDIUM |
| 3–4 | HIGH |
| 5+ | CRITICAL |

An email is sent only for HIGH and CRITICAL levels.

---

## Metrics Scored

| Metric | Warn | Crit | Source |
|---|---|---|---|
| rpool capacity | 75% | 85% | `RPOOL_CAPACITY` |
| rpool fragmentation | 40% | 60% | `RPOOL_FRAGMENTATION` |
| NVMe IO latency | 10ms | 25ms | `NVME_AWAIT_MS` |
| RAM usage | 80% | 90% | `RAM_USED_PCT` |
| NVMe container partition | 75% | 85% | `NVME_PARTITION_CAP` |
| NVMe wear (per drive) | 70% | 85% | `NVME_nvme*_USED` |

All thresholds are sourced from `forensic-config.sh`.

---

## Dependencies

- `forensic-config.sh` at `/root/forensic-config.sh`
- At least one metrics file in `/root/forensic-history/metrics/`
- Run `collect-metrics.sh` first if no metrics files exist

---

## Install

```bash
cp score-metrics.sh /usr/local/bin/
chmod +x /usr/local/bin/score-metrics.sh
```

Run manually after `collect-metrics.sh`:
```bash
/usr/local/bin/score-metrics.sh
```

---

## Script

```bash
#!/usr/bin/env bash
#
# score-metrics.sh
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)
# Deterministic risk scoring against latest metrics file.
# Emails on HIGH or CRITICAL risk level.

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

# NVMe wear per drive
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
```
