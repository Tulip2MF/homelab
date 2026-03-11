#!/usr/bin/env bash
#
# quarterly-report.sh
#
# ROLE:        operator-assisted verification
# AUTHORITY:   none
# FAIL MODE:   closed
# AUTO-REPAIR: forbidden
#
# Runs on: Proxmox Host (192.168.178.127)
#
# PURPOSE:
#   Unified quarterly report. Consolidates output from:
#     - forensic-dump.sh     (system state snapshot)
#     - collect-metrics.sh   (numeric drift data)
#     - score-metrics.sh     (risk scoring)
#     - anomaly-detection.sh (statistical anomaly detection)
#     - predict-capacity.sh  (capacity exhaustion modeling)
#     - verify-integrity.sh  (forensic chain integrity)
#
#   Produces a single readable summary report and emails it to root.
#   Exits non-zero if any subsystem reports HIGH/CRITICAL risk or failures.
#
# USAGE:
#   Run manually after all quarterly scripts have completed, OR
#   schedule after all other quarterly crons on the same day.
#
#   sudo /usr/local/bin/quarterly-report.sh 2>&1 | tee /var/log/quarterly-report-$(date +%F).log
#
# Cron (Proxmox host -- quarterly, last in the sequence at 08:00):
#   0 8 1 1,4,7,10 *   /usr/local/bin/quarterly-report.sh >> /var/log/quarterly-report.log 2>&1

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

# ── Helper: section header ────────────────────────────────────────────────────
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

# ────────────────────────────────────────────────────────────────────────────
section "1. METRICS SNAPSHOT"

LATEST_METRICS=$(ls -t "${METRICS_DIR}"/metrics-*.txt 2>/dev/null | head -1 || true)

if [ -z "$LATEST_METRICS" ]; then
    flag_issue "No metrics file found -- has collect-metrics.sh run this quarter?"
    echo "  No metrics available."
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

    # Per-drive NVMe wear
    echo ""
    echo "  NVMe wear (percentage_used):"
    grep -E '^NVME_nvme[0-9]+n[0-9]+_USED=' "$LATEST_METRICS" | while IFS='=' read -r KEY VAL; do
        DRIVE="${KEY#NVME_}"
        DRIVE="${DRIVE%_USED}"
        printf "    %-26s %s%%\n" "${DRIVE}:" "$VAL"
    done

    # Threshold annotations
    echo ""
    echo "  Threshold reference (from forensic-config.sh):"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "rpool capacity:"    "$RPOOL_WARN"  "$RPOOL_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "fragmentation:"     "$FRAG_WARN"   "$FRAG_CRIT"
    printf "    %-30s warn=%sms  crit=%sms\n" "NVMe latency:"      "$AWAIT_WARN"  "$AWAIT_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "NVMe wear:"         "$NVME_WARN"   "$NVME_CRIT"
    printf "    %-30s warn=%s%%  crit=%s%%\n" "RAM:"               "$RAM_WARN"    "$RAM_CRIT"
fi

# ────────────────────────────────────────────────────────────────────────────
section "2. RISK SCORE"

RISK_OUTPUT=$(bash /usr/local/bin/score-metrics.sh 2>/dev/null || true)
if [ -z "$RISK_OUTPUT" ]; then
    flag_issue "score-metrics.sh produced no output -- check metrics files"
    echo "  No scoring output available."
else
    echo "$RISK_OUTPUT" | sed 's/^/  /'
    RISK_LEVEL=$(echo "$RISK_OUTPUT" | grep "^RISK_LEVEL=" | cut -d= -f2 || echo "UNKNOWN")
    if [ "$RISK_LEVEL" = "HIGH" ] || [ "$RISK_LEVEL" = "CRITICAL" ]; then
        flag_issue "Risk level is ${RISK_LEVEL} -- review metrics and take action"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
section "3. ANOMALY DETECTION"

ANOMALY_LOG=$(ls -t /var/log/anomaly-detection-*.log 2>/dev/null | head -1 || true)
if [ -z "$ANOMALY_LOG" ]; then
    flag_issue "No anomaly detection log found -- has anomaly-detection.sh run this quarter?"
    echo "  No anomaly log available."
else
    echo "  Source: ${ANOMALY_LOG}"
    echo ""
    cat "$ANOMALY_LOG" | sed 's/^/  /'
    if grep -q "^ANOMALY:" "$ANOMALY_LOG" 2>/dev/null; then
        COUNT=$(grep -c "^ANOMALY:" "$ANOMALY_LOG" || echo 0)
        flag_issue "${COUNT} anomaly(ies) detected -- see section above"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
section "4. CAPACITY PREDICTION"

echo "  Linear extrapolation from last 10 quarterly samples:"
echo ""
PREDICT_OUTPUT=$(bash /usr/local/bin/predict-capacity.sh 2>/dev/null || true)
if [ -z "$PREDICT_OUTPUT" ]; then
    echo "  Insufficient data for prediction (need 5+ quarterly samples)."
else
    echo "$PREDICT_OUTPUT" | sed 's/^/  /'

    # Flag if exhaustion is predicted within 4 samples (1 year)
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
        if echo "$LINE" | grep -q "ALREADY AT OR BEYOND CRITICAL"; then
            flag_issue "$LINE"
        fi
    done <<< "$PREDICT_OUTPUT"
fi

# ────────────────────────────────────────────────────────────────────────────
section "5. FORENSIC DUMP INVENTORY"

DUMP_COUNT=$(ls "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | wc -l || echo 0)
LATEST_DUMP=$(ls -t "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | head -1 || true)
OLDEST_DUMP=$(ls "${DUMP_DIR}"/system-dump-*.txt 2>/dev/null | sort | head -1 || true)

echo "  Dump directory  : ${DUMP_DIR}"
echo "  Total dumps     : ${DUMP_COUNT}"
echo "  Latest dump     : ${LATEST_DUMP:-none}"
echo "  Oldest dump     : ${OLDEST_DUMP:-none}"

if [ -z "$LATEST_DUMP" ]; then
    flag_issue "No forensic dumps found -- has forensic-dump.sh ever run?"
else
    DUMP_AGE=$(( ( $(date +%s) - $(stat -c %Y "$LATEST_DUMP") ) / 86400 ))
    if [ "$DUMP_AGE" -gt 100 ]; then
        flag_issue "Latest dump is ${DUMP_AGE} days old -- expected quarterly (<=93 days)"
    else
        echo "  Latest dump age : ${DUMP_AGE} days (OK)"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
section "6. INTEGRITY CHAIN"

if [ ! -f "$CHAIN" ]; then
    flag_issue "Integrity chain not found at ${CHAIN} -- run update-integrity-chain.sh"
    echo "  No integrity chain exists yet."
else
    CHAIN_ENTRIES=$(grep -c '|' "$CHAIN" 2>/dev/null || echo 0)
    echo "  Chain file      : ${CHAIN}"
    echo "  Entries         : ${CHAIN_ENTRIES}"

    # Check append-only flag
    if command -v lsattr >/dev/null 2>&1; then
        ATTRS=$(lsattr "$CHAIN" 2>/dev/null | awk '{print $1}')
        if echo "$ATTRS" | grep -q 'a'; then
            echo "  Append-only     : SET (tamper-resistant)"
        else
            flag_issue "Integrity chain append-only flag NOT SET -- run: chattr +a ${CHAIN}"
        fi
    fi

    echo ""
    echo "  Running verification..."
    echo ""
    VERIFY_OUTPUT=$(bash /usr/local/bin/verify-integrity.sh 2>/dev/null || true)
    echo "$VERIFY_OUTPUT" | sed 's/^/  /'

    if echo "$VERIFY_OUTPUT" | grep -qE "^\[TAMPERED\]|^\[MISSING\]"; then
        TAMPER_COUNT=$(echo "$VERIFY_OUTPUT" | grep -cE "^\[TAMPERED\]|^\[MISSING\]" || echo 0)
        flag_issue "${TAMPER_COUNT} integrity failure(s) detected -- forensic dumps may be compromised"
    fi
fi

# ────────────────────────────────────────────────────────────────────────────
section "7. METRICS HISTORY (LAST 8 QUARTERS)"

METRICS_FILES=$(ls -t "${METRICS_DIR}"/metrics-*.txt 2>/dev/null | head -8 | tac || true)
if [ -z "$METRICS_FILES" ]; then
    echo "  No historical metrics available yet."
else
    printf "  %-25s %-10s %-10s %-12s %-10s %-10s\n" \
        "DATE" "RPOOL%" "FRAG%" "NVME_PART%" "RAM%" "AWAIT_MS"
    printf "  %-25s %-10s %-10s %-12s %-10s %-10s\n" \
        "─────────────────────" "────────" "──────" "──────────" "──────" "────────"
    while IFS= read -r MFILE; do
        [ -z "$MFILE" ] && continue
        D=$(grep    "^DATE="                "$MFILE" | cut -d= -f2 || echo "?")
        R=$(grep    "^RPOOL_CAPACITY="      "$MFILE" | cut -d= -f2 || echo "?")
        F=$(grep    "^RPOOL_FRAGMENTATION=" "$MFILE" | cut -d= -f2 || echo "?")
        NP=$(grep   "^NVME_PARTITION_CAP="  "$MFILE" | cut -d= -f2 || echo "?")
        RA=$(grep   "^RAM_USED_PCT="        "$MFILE" | cut -d= -f2 || echo "?")
        AW=$(grep   "^NVME_AWAIT_MS="       "$MFILE" | cut -d= -f2 || echo "?")
        printf "  %-25s %-10s %-10s %-12s %-10s %-10s\n" "$D" "$R" "$F" "$NP" "$RA" "$AW"
    done <<< "$METRICS_FILES"
fi

# ────────────────────────────────────────────────────────────────────────────
section "8. SUMMARY"

echo "  Quarter         : ${QUARTER}"
echo "  Report date     : ${DATE}"
echo "  Issues found    : ${ISSUES}"
echo "  Overall status  : ${OVERALL_STATUS}"
echo ""

if [ "$ISSUES" -gt 0 ]; then
    echo "  ISSUES REQUIRING ATTENTION:"
    echo "  (search this report for ⚠ markers above)"
fi

echo ""
echo "  Next quarterly run: $(date -d "+3 months" +%F 2>/dev/null || date -v+3m +%F 2>/dev/null || echo 'in ~3 months')"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  END OF REPORT"
echo "════════════════════════════════════════════════════════════"

} > "$REPORT"

# ── Print to stdout ───────────────────────────────────────────────────────────
cat "$REPORT"

# ── Email report ──────────────────────────────────────────────────────────────
SUBJECT="[HOMELAB QUARTERLY ${QUARTER}] Status: ${OVERALL_STATUS} | ${ISSUES} issue(s)"
mail -s "$SUBJECT" root < "$REPORT" 2>/dev/null || true

echo ""
echo "[QUARTERLY-REPORT] Written to: ${REPORT}"

# ── Rotate old quarterly reports (keep 2 years) ───────────────────────────────
find /root/forensic-history -maxdepth 1 -name "quarterly-report-*.txt" \
    -mtime +730 -delete 2>/dev/null || true

[ "$ISSUES" -gt 0 ] && exit 1
exit 0
