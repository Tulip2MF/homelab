#!/usr/bin/env bash
#
# forensic-config.sh
#
# Single source of truth for all operational thresholds.
# Sourced by: score-metrics.sh, predict-capacity.sh, anomaly-detection.sh
#
# Network reference:
#   Proxmox host  192.168.178.127
#   TrueNAS VM    192.168.178.139
#   PBS Mini PC   192.168.178.142
#   Debian VM     192.168.178.141

# ZFS rpool capacity (%)
RPOOL_WARN=75
RPOOL_CRIT=85

# ZFS fragmentation (%)
FRAG_WARN=40
FRAG_CRIT=60

# NVMe wear -- Samsung 990 PRO percentage_used (direct, no inversion)
# 70% used = 30% life remaining = WARN
# 85% used = 15% life remaining = CRIT
NVME_WARN=70
NVME_CRIT=85

# NVMe IO latency (ms)
AWAIT_WARN=10
AWAIT_CRIT=25

# RAM usage (system has 48GB -- one DIMM removed/failed)
RAM_WARN=80
RAM_CRIT=90

ALERT_EMAIL="root"
