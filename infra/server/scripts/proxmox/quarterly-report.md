# quarterly-report.sh

Unified quarterly report. Consolidates output from all five quarterly subsystems into a single readable summary and emails it to root. The last script to run in the quarterly sequence.

**Host:** Main Server — Proxmox `192.168.178.127`
**Install path:** `/usr/local/bin/quarterly-report.sh`
**Cron:** `0 8 1 1,4,7,10 *   /usr/local/bin/quarterly-report.sh >> /var/log/quarterly-report.log 2>&1`
**Classification:** Operator-Only

---

## Purpose

Aggregates and presents the output of all quarterly scripts in one place. Runs after all other quarterly scripts have completed on the same day and calls `score-metrics.sh`, `predict-capacity.sh`, and `verify-integrity.sh` directly to produce a composite view.

Exits non-zero if any subsystem reports HIGH/CRITICAL risk or integrity failures. The email subject line always includes the overall status and issue count.

---

## Report Sections

| Section | Source |
|---|---|
| 1. Metrics Snapshot | Latest file from `/root/forensic-history/metrics/` |
| 2. Risk Score | Output of `score-metrics.sh` |
| 3. Anomaly Detection | Latest `/var/log/anomaly-detection-*.log` |
| 4. Capacity Prediction | Output of `predict-capacity.sh` |
| 5. Forensic Dump Inventory | Files in `/root/forensic-history/dumps/` |
| 6. Integrity Chain | Output of `verify-integrity.sh` |
| 7. Metrics History | Table of last 8 quarters |
| 8. Summary | Overall status, issue count, next run date |

---

## Email Subject Format

```
[HOMELAB QUARTERLY 2026-Q1] Status: OK | 0 issue(s)
[HOMELAB QUARTERLY 2026-Q2] Status: ACTION REQUIRED | 2 issue(s)
```

---

## Issue Escalation Thresholds

`quarterly-report.sh` flags items as issues requiring attention when:

| Condition | Action |
|---|---|
| Risk level is HIGH or CRITICAL | Flagged as issue |
| Anomaly detected in any metric | Flagged as issue |
| Capacity exhaustion < 4 quarters away | Flagged as CRITICAL issue |
| Capacity exhaustion 4–8 quarters away | Flagged as WARNING issue |
| Forensic dump missing or > 100 days old | Flagged as issue |
| Integrity chain missing or has failures | Flagged as issue |

---

## Full Quarterly Cron Sequence

All five scripts must run in order on the same day:

```
0 5 1 1,4,7,10 *    /usr/local/bin/forensic-dump.sh
30 5 1 1,4,7,10 *   /usr/local/bin/update-integrity-chain.sh
0 6 1 1,4,7,10 *    /usr/local/bin/collect-metrics.sh
0 7 1 1,4,7,10 *    /usr/local/bin/anomaly-detection.sh
0 8 1 1,4,7,10 *    /usr/local/bin/quarterly-report.sh
```

`score-metrics.sh`, `predict-capacity.sh`, and `verify-integrity.sh` are called internally by `quarterly-report.sh`.

---

## Key Files

| File | Purpose |
|---|---|
| `/root/forensic-history/quarterly-report-YYYY-MM-DD.txt` | Full report written here, then emailed |
| `/root/forensic-history/` | Parent directory for all forensic history |

Old reports are auto-rotated after 2 years (730 days).

---

## Dependencies

- `forensic-config.sh` at `/root/forensic-config.sh`
- `score-metrics.sh`, `predict-capacity.sh`, `verify-integrity.sh` all installed
- At least one metrics file and one forensic dump

---

## Install

```bash
cp quarterly-report.sh /usr/local/bin/
chmod +x /usr/local/bin/quarterly-report.sh
mkdir -p /root/forensic-history
```

Add to crontab on Proxmox (`crontab -e`):
```
0 8 1 1,4,7,10 *   /usr/local/bin/quarterly-report.sh >> /var/log/quarterly-report.log 2>&1
```

Run manually to test (after the other quarterly scripts have run):
```bash
sudo /usr/local/bin/quarterly-report.sh 2>&1 | tee /var/log/quarterly-report-$(date +%F).log
```

---

## Script

```bash
#!/usr/bin/env bash
#
# quarterly-report.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Main Server — Main Server — Proxmox (192.168.178.127)

set -euo pipefail

source /root/forensic-config.sh

DATE=$(date +%F)
QUARTER=$(date +%Y-Q$(( ($(date +%-m) - 1) / 3 + 1 )))
REPORT="/root/forensic-history/quarterly-report-${DATE}.txt"
METRICS_DIR="/root/forensic-history/metrics"
DUMP_DIR="/root/forensic-history/dumps"
CHAIN="${DUMP_DIR}/integrity-chain.txt"

OVERALL_STATUS="OK"
ISSUES=0

mkdir -p /root/forensic-history

section() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  $1"
    echo "════════════════════════════════════════════════════════════"
}

flag_issue() {
    echo "  ⚠  $1"
    ISSUES=$(( ISSUES + 1 ))
    OVERALL_STATUS="ACTION REQUIRED"
}

{

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         HOMELAB QUARTERLY OPERATIONAL REPORT                ║"
echo "║         ${QUARTER}  —  Generated: ${DATE}              ║"
echo "║         Host: Proxmox 192.168.178.127                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

section "1. METRICS SNAPSHOT"

LATEST_METRICS=$(ls -t "${METRICS_DIR}"/metrics-*.txt 2>/dev/null | head -1 || true)

if [ -z "$LATEST_METRICS" ]; then
    flag_issue "No metrics file found -- has collect-metrics.sh run this quarter?"
else
    echo "  Source: ${LATEST_METRICS}"
    echo ""

    RPOOL=$(grep    "^RPOOL_CAPACITY="      "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")
    FRAG=$(grep     "^RPOOL_FRAGMENTATION=" "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")
    AWAIT=$(grep    "^NVME_AWAIT_MS="       "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")
    RAM=$(grep      "^RAM_USED_PCT="        "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")
    NVME_PART=$(grep "^NVME_PARTITION_CAP=" "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")
    RAM_TOTAL=$(grep "^RAM_TOTAL_MB="       "$LATEST_METRICS" | cut -d= -f2 || echo "N/A")

    printf "  %-30s %s%%\n"   "rpool capacity:"           "$RPOOL"
    printf "  %-30s %s%%\n"   "rpool fragmentation:"      "$FRAG"
    printf "  %-30s %sms\n"   "NVMe IO latency (await):"  "$AWAIT"
    printf "  %-30s %s%%\n"   "NVMe container partition:" "$NVME_PART"
    printf "  %-30s %s%%\n"   "RAM pressure:"             "$RAM"
    printf "  %-30s %sMB\n"   "RAM total:"                "$RAM_TOTAL"

    echo ""
    echo "  NVMe wear (percentage_used):"
    grep -E '^NVME_nvme[0-9]+n[0-9]+_USED=' "$LATEST_METRICS" | while IFS='=' read -r KEY VAL; do
        DRIVE="${KEY#NVME_}"; DRIVE="${DRIVE%_USED}"
        printf "    %-26s %s%%\n" "${DRIVE}:" "$VAL"
    done

    echo ""
    echo "  Threshold reference:"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "rpool capacity:"    "$RPOOL_WARN"  "$RPOOL_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "fragmentation:"     "$FRAG_WARN"   "$FRAG_CRIT"
    printf "    %-30s warn=%sms  crit=%sms\n" "NVMe latency:"      "$AWAIT_WARN"  "$AWAIT_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "NVMe wear:"         "$NVME_WARN"   "$NVME_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "RAM:"               "$RAM_WARN"    "$RAM_CRIT"
fi

section "2. RISK SCORE"

RISK_OUTPUT=$(bash /usr/local/bin/score-metrics.sh 2>/dev/null || true)
if [ -z "$RISK_OUTPUT" ]; then
    flag_issue "score-metrics.sh produced no output"
else
    echo "$RISK_OUTPUT" | sed 's/^/  /'
    RISK_LEVEL=$(echo "$RISK_OUTPUT" | grep "^RISK_LEVEL=" | cut -d= -f2 || echo "UNKNOWN")
    if [ "$RISK_LEVEL" = "HIGH" ] || [ "$RISK_LEVEL" = "CRITICAL" ]; then
        flag_issue "Risk level is ${RISK_LEVEL} -- review metrics and take action"
    fi
fi

section "3. ANOMALY DETECTION"

ANOMALY_LOG=$(ls -t /var/log/anomaly-detection-*.log 2>/dev/null | head -1 || true)
if [ -z "$ANOMALY_LOG" ]; then
    flag_issue "No anomaly detection log found -- has anomaly-detection.sh run this quarter?"
else
    echo "  Source: ${ANOMALY_LOG}"
    echo ""
    cat "$ANOMALY_LOG" | sed 's/^/  /'
    if grep -q "^ANOMALY:" "$ANOMALY_LOG" 2>/dev/null; then
        COUNT=$(grep -c "^ANOMALY:" "$ANOMALY_LOG" || echo 0)
        flag_issue "${COUNT} anomaly(ies) detected"
    fi
fi

section "4. CAPACITY PREDICTION"

echo "  Linear extrapolation from last 10 quarterly samples:"
echo ""
PREDICT_OUTPUT=$(bash /usr/local/bin/predict-capacity.sh 2>/dev/null || true)
if [ -z "$PREDICT_OUTPUT" ]; then
    echo "  Insufficient data for prediction (need 5+ quarterly samples)."
else
    echo "$PREDICT_OUTPUT" | sed 's/^/  /'
    while IFS= read -r LINE; do
        if echo "$LINE" | grep -qE "^[^:]+: [0-9]+ quarterly"; then
            SAMPLES=$(echo "$LINE" | grep -oE '[0-9]+ quarterly' | grep -oE '[0-9]+')
            LABEL=$(echo "$LINE" | cut -d: -f1)
            if [ "$SAMPLES" -lt 4 ]; then
                flag_issue "${LABEL}: CRITICAL exhaustion within ${SAMPLES} quarters"
            elif [ "$SAMPLES" -lt 8 ]; then
                flag_issue "${LABEL}: WARNING exhaustion within ${SAMPLES} quarters (< 2 years)"
            fi
        fi
        echo "$LINE" | grep -q "ALREADY AT OR BEYOND CRITICAL" && flag_issue "$LINE"
    done <<< "$PREDICT_OUTPUT"
fi

section "5. FORENSIC DUMP INVENTORY"

DUMP_COUNT=$(ls "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | wc -l || echo 0)
LATEST_DUMP=$(ls -t "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | head -1 || true)
OLDEST_DUMP=$(ls "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | sort | head -1 || true)

echo "  Total dumps : ${DUMP_COUNT}"
echo "  Latest dump : ${LATEST_DUMP:-none}"
echo "  Oldest dump : ${OLDEST_DUMP:-none}"

if [ -z "$LATEST_DUMP" ]; then
    flag_issue "No forensic dumps found"
else
    DUMP_AGE=$(( ( $(date +%s) - $(stat -c %Y "$LATEST_DUMP") ) / 86400 ))
    [ "$DUMP_AGE" -gt 100 ] \
        && flag_issue "Latest dump is ${DUMP_AGE} days old -- expected quarterly (<= 93 days)" \
        || echo "  Latest dump age : ${DUMP_AGE} days (OK)"
fi

section "6. INTEGRITY CHAIN"

if [ ! -f "$CHAIN" ]; then
    flag_issue "Integrity chain not found at ${CHAIN}"
else
    CHAIN_ENTRIES=$(grep -c '|' "$CHAIN" 2>/dev/null || echo 0)
    echo "  Chain file : ${CHAIN}"
    echo "  Entries    : ${CHAIN_ENTRIES}"

    if command -v lsattr >/dev/null 2>&1; then
        ATTRS=$(lsattr "$CHAIN" 2>/dev/null | awk '{print $1}')
        echo "$ATTRS" | grep -q 'a' \
            && echo "  Append-only: SET (tamper-resistant)" \
            || flag_issue "Integrity chain append-only flag NOT SET -- run: chattr +a ${CHAIN}"
    fi

    echo ""
    VERIFY_OUTPUT=$(bash /usr/local/bin/verify-integrity.sh 2>/dev/null || true)
    echo "$VERIFY_OUTPUT" | sed 's/^/  /'

    if echo "$VERIFY_OUTPUT" | grep -qE "^\[TAMPERED\]|\[MISSING\]"; then
        TAMPER_COUNT=$(echo "$VERIFY_OUTPUT" | grep -cE "^\[TAMPERED\]|\[MISSING\]" || echo 0)
        flag_issue "${TAMPER_COUNT} integrity failure(s) detected"
    fi
fi

section "7. METRICS HISTORY (LAST 8 QUARTERS)"

METRICS_FILES=$(ls -t "${METRICS_DIR}"/metrics-*.txt 2>/dev/null | head -8 | tac || true)
if [ -z "$METRICS_FILES" ]; then
    echo "  No historical metrics available yet."
else
    printf "  %-25s %-10s %-10s %-12s %-10s %-10s\n" "DATE" "RPOOL%" "FRAG%" "NVME_PART%" "RAM%" "AWAIT_MS"
    while IFS= read -r MFILE; do
        [ -z "$MFILE" ] && continue
        D=$(grep  "^DATE="                "$MFILE" | cut -d= -f2 || echo "?")
        R=$(grep  "^RPOOL_CAPACITY="      "$MFILE" | cut -d= -f2 || echo "?")
        F=$(grep  "^RPOOL_FRAGMENTATION=" "$MFILE" | cut -d= -f2 || echo "?")
        NP=$(grep "^NVME_PARTITION_CAP="  "$MFILE" | cut -d= -f2 || echo "?")
        RA=$(grep "^RAM_USED_PCT="        "$MFILE" | cut -d= -f2 || echo "?")
        AW=$(grep "^NVME_AWAIT_MS="       "$MFILE" | cut -d= -f2 || echo "?")
        printf "  %-25s %-10s %-10s %-12s %-10s %-10s\n" "$D" "$R" "$F" "$NP" "$RA" "$AW"
    done <<< "$METRICS_FILES"
fi

section "8. SUMMARY"

echo "  Quarter      : ${QUARTER}"
echo "  Report date  : ${DATE}"
echo "  Issues found : ${ISSUES}"
echo "  Overall      : ${OVERALL_STATUS}"
echo ""
[ "$ISSUES" -gt 0 ] && echo "  ISSUES: search this report for ⚠ markers above"
echo ""
echo "  Next run: $(date -d "+3 months" +%F 2>/dev/null || echo 'in ~3 months')"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  END OF REPORT"
echo "════════════════════════════════════════════════════════════"

} > "$REPORT"

cat "$REPORT"

SUBJECT="[HOMELAB QUARTERLY ${QUARTER}] Status: ${OVERALL_STATUS} | ${ISSUES} issue(s)"
mail -s "$SUBJECT" root < "$REPORT" 2>/dev/null || true

echo ""
echo "[QUARTERLY-REPORT] Written to: ${REPORT}"

find /root/forensic-history -maxdepth 1 -name "quarterly-report-*.txt" \
    -mtime +730 -delete 2>/dev/null || true

[ "$ISSUES" -gt 0 ] && exit 1
exit 0
```
