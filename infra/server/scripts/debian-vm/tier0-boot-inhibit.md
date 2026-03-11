# tier0-boot-inhibit.service

Systemd service that sets the backup inhibit immediately on boot, before any other service starts. Ensures backups never run after a reboot until Tier-0 has been fully verified by `monitor-backups.sh`.

**Host:** Debian VM `192.168.178.141`
**Install path:** `/etc/systemd/system/tier0-boot-inhibit.service`
**Cron:** None — triggered by systemd on every boot
**Classification:** Executor

---

## Purpose

After a reboot, system state is unknown. The previous heartbeat is stale, NFS mounts may not yet be up, and the PBS marker on TrueNAS reflects pre-reboot conditions. If backups were allowed to run immediately, they could run against an unverified system.

This service writes `/var/run/backup_inhibit` and deletes the stale heartbeat file as the very first act on boot — before `network.target` and before `cron.service`. The inhibit stays in place until `monitor-backups.sh` runs its full evaluation (within 5 minutes of cron starting) and clears it.

---

## Boot Sequence

```
Boot
 └── tier0-boot-inhibit.service   ← writes inhibit, removes stale heartbeat
      └── network.target
           └── cron.service
                └── */5 monitor-backups.sh  ← clears inhibit if all checks pass
```

---

## Key Files

| File | Purpose |
|---|---|
| `/var/run/backup_inhibit` | Created on boot with a REBOOT timestamp message |
| `/var/run/tier0_heartbeat` | Deleted on boot — stale from before reboot |
| `/etc/systemd/system/tier0-boot-inhibit.service` | Service unit file |

---

## Install

```bash
cp tier0-boot-inhibit.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable tier0-boot-inhibit.service

# Verify it is enabled
systemctl is-enabled tier0-boot-inhibit.service
# Expected: enabled

# Verify it runs at next boot by checking it ran this session
systemctl status tier0-boot-inhibit.service
```

---

## Verify After Reboot

```bash
# Immediately after reboot -- inhibit should be set with REBOOT message
cat /var/run/backup_inhibit
# Expected: REBOOT 2026-03-11T07:00:00+00:00 -- state UNKNOWN, awaiting Tier-0 verification

# After ~5 minutes -- monitor-backups.sh should have cleared it
ls /var/run/backup_inhibit
# Expected: No such file or directory

cat /var/run/tier0_heartbeat
# Expected: file exists with recent timestamp
```

---

## Service File

```ini
[Unit]
Description=Tier-0 Boot Inhibit -- set backup_inhibit until monitoring verifies
Documentation=State is UNKNOWN after reboot. Inhibit must exist until monitor-backups.sh clears it.
DefaultDependencies=no
Before=network.target
Before=cron.service

[Service]
Type=oneshot
# Create inhibit with a reboot marker so logs show WHY it was set
ExecStart=/bin/bash -c 'echo "REBOOT $(date --iso-8601=seconds) -- state UNKNOWN, awaiting Tier-0 verification" > /var/run/backup_inhibit'
# Remove stale heartbeat -- it is from before the reboot and is now meaningless
ExecStart=/bin/rm -f /var/run/tier0_heartbeat
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```
