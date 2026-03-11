#!/usr/bin/env bash
#
# forensic-dump.sh
#
# Runs on: Proxmox Host (192.168.178.127)
# Read-only point-in-time system snapshot for quarterly review and incident analysis.
# Makes NO changes to the system.
#
# Cron (Proxmox host -- quarterly):
#   0 5 1 1,4,7,10 *   /usr/local/bin/forensic-dump.sh

set -euo pipefail

DATE=$(date +%F)
OUT="/root/forensic-history/dumps/system-dump-${DATE}.txt"

mkdir -p "$(dirname "$OUT")"

{

echo "===== DATE =====" && date
echo "" && echo "===== SYSTEM INFO =====" && uname -a && uptime

echo "" && echo "===== RAM STATE ====="
# System has 48GB RAM (one DIMM removed -- was corrupt).
# Expected RAM_TOTAL ~48000 MB. If significantly lower, another DIMM may have failed.
free -h
echo ""
free -m | awk '/^Mem:/ {
    pct=int($3/$2*100)
    print "RAM used: " pct "%"
    if (pct >= 90)      print "WARNING: RAM CRITICAL (>= 90%)"
    else if (pct >= 80) print "NOTICE: RAM elevated (>= 80%)"
    else                print "RAM: nominal"
}'

echo "" && echo "===== NETWORK =====" && ip -br addr && ip route

echo "" && echo "===== CPU + IO =====" && top -bn1 | head -20

if command -v iostat >/dev/null 2>&1; then
    echo "" && echo "===== IOSTAT =====" && iostat -xy 1 5
fi

echo "" && echo "===== ZFS STATUS =====" && zpool status -v
zpool list -v -o name,size,alloc,free,capacity,health,fragmentation

echo "" && echo "===== ZFS EVENTS (last 100) =====" && zpool events -v | tail -100

echo "" && echo "===== NVMe SMART (Samsung 990 PRO) ====="
for drive in /dev/nvme[0-9]n1; do
    [ -e "$drive" ] && echo "--- $drive ---" && nvme smart-log "$drive"
done

echo "" && echo "===== HDD / SAS HEALTH NOTE ====="
# 5 HDDs (3x4TB + 2x8TB) via LSI SAS 9300-16i passed through to TrueNAS VM (192.168.178.139).
# SMART data is NOT visible from Proxmox. Check TrueNAS for HDD health.
echo "HDDs passed through to TrueNAS VM (192.168.178.139) via LSI SAS HBA -- SMART not visible here."
echo "Check TrueNAS storage dashboard for HDD health and ZFS pool status."

echo "" && echo "===== KERNEL + OOM EVENTS (last 100) ====="
dmesg -T | grep -Ei 'error|fail|critical|mce|segfault|dma|iommu|out of memory|killed process' | tail -100

echo "" && echo "===== JOURNAL ERRORS =====" && journalctl -p 3 -xb -n 500
echo "" && echo "===== PVE TASK ERRORS =====" && grep -i error /var/log/pve/tasks/* 2>/dev/null | tail -200
echo "" && echo "===== GUI ACCESS LOG =====" && tail -n 50 /var/log/pveproxy/access.log 2>/dev/null
echo "" && echo "===== VM STATUS =====" && qm list

} > "$OUT"

echo "Forensic dump written to ${OUT}"

# Update integrity chain immediately after dump is written.
# This hashes the dump and appends the entry to integrity-chain.txt.
if [ -x /usr/local/bin/update-integrity-chain.sh ]; then
    /usr/local/bin/update-integrity-chain.sh \
        && echo "Integrity chain updated." \
        || echo "WARN: integrity chain update failed -- run update-integrity-chain.sh manually" >&2
else
    echo "WARN: update-integrity-chain.sh not found at /usr/local/bin/ -- install it" >&2
fi
