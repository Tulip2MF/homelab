# Homelab Deployment Guide
## Tier-0 Backup & Integrity Framework
### Step-by-Step Installation & Configuration

| Host | IP |
|---|---|
| Proxmox Host | 192.168.178.127 |
| TrueNAS VM | 192.168.178.139 |
| PBS Mini PC | 192.168.178.142 |
| Debian VM | 192.168.178.141 |

> **20 scripts · 4 hosts · Read all steps before starting**

All scripts are available at:  
**https://github.com/Tulip2MF/homelab/tree/main/infra/server/scripts**

---

## Overview

This guide walks you through installing all 20 scripts across all four hosts. Complete each host section fully before moving to the next. The order matters: TrueNAS must be prepared first because all other hosts depend on it.

**Recommended installation order:**

1. **Step 1 — TrueNAS** (`192.168.178.139`) — NFS exports and healthcheck user
2. **Step 2 — PBS Mini PC** (`192.168.178.142`) — NFS mount and marker script
3. **Step 3 — Proxmox Host** (`192.168.178.127`) — NVMe health, forensic, analytics scripts
4. **Step 4 — Debian VM** (`192.168.178.141`) — Main monitoring and backup scripts
5. **Step 5 — Verification** — Confirm everything is connected and working

> ⚠️ All commands in this guide are run as root unless stated otherwise. Use `sudo -i` or log in as root before starting.

---

## Script Inventory

### Debian VM (primary monitoring host) — `192.168.178.141`

| Script | Install path | Purpose |
|---|---|---|
| `monitor-backups.sh` | `/usr/local/bin/` | Tier-0 evaluator — runs every 5 min, sets/clears inhibit |
| `check-nfs-health.sh` | `/usr/local/bin/` | Standalone NFS health check — runs hourly |
| `dump-databases.sh` | `/usr/local/bin/` | Nightly Postgres + Redis dumps to TrueNAS NFS |
| `backup-filen-rclone.sh` | `/usr/local/bin/` | Weekly rclone encrypted upload to Filen Cloud |
| `homelab-daily-report.sh` | `/usr/local/bin/` | Daily status email — the consolidated health summary |
| `test-restore.sh` | `/usr/local/bin/` | Monthly manual restore verification |
| `tier0-boot-inhibit.service` | `/etc/systemd/system/` | Sets inhibit on every boot until Tier-0 clears it |

### Proxmox Host (analytics + forensic) — `192.168.178.127`

| Script | Install path | Purpose |
|---|---|---|
| `check-nvme-health.sh` | `/usr/local/bin/` | Daily NVMe SMART, wear, capacity and rpool ZFS health |
| `forensic-config.sh` | `/root/` | Shared threshold config sourced by analytics scripts |
| `collect-metrics.sh` | `/usr/local/bin/` | Quarterly numeric metrics collection |
| `score-metrics.sh` | `/usr/local/bin/` | Quarterly risk scoring — emails on HIGH/CRITICAL |
| `anomaly-detection.sh` | `/usr/local/bin/` | Quarterly anomaly detection — emails if spike detected |
| `predict-capacity.sh` | `/usr/local/bin/` | Quarterly capacity exhaustion prediction |
| `forensic-dump.sh` | `/usr/local/bin/` | Quarterly full system snapshot |
| `update-integrity-chain.sh` | `/usr/local/bin/` | SHA256 chain updater — called by `forensic-dump.sh` |
| `verify-integrity.sh` | `/usr/local/bin/` | Manual integrity chain verifier |
| `quarterly-report.sh` | `/usr/local/bin/` | Quarterly unified report email |
| `prune-forensic-history.sh` | `/usr/local/bin/` | Annual retention enforcement |

### PBS Mini PC — `192.168.178.142`

| Script | Install path | Purpose |
|---|---|---|
| `pbs-write-marker.sh` | `/usr/local/bin/` | Writes success marker to TrueNAS NFS after nightly backup |

---

## Step 1 — TrueNAS VM `192.168.178.139`

No scripts are installed on TrueNAS. This step prepares TrueNAS to support all other hosts: creating the healthcheck user for SSH-based pool monitoring, and configuring NFS exports so PBS and the Debian VM can mount the backup dataset.

### 1.1 Create the healthcheck user

The Debian VM SSHs to TrueNAS as a limited user to read ZFS pool health. This avoids storing root credentials on the Debian VM.

1. Open TrueNAS web UI → **Credentials → Local Users → Add**
2. Username: `healthcheck`
3. Set a password (not used for SSH key login but required by TrueNAS)
4. Shell: `bash` (or `nologin` — SSH key auth only, no interactive login needed)
5. Save the user

### 1.2 Configure sudo for `zpool list`

The healthcheck user needs exactly one sudo permission: read the ZFS pool health. Nothing else.

1. Open TrueNAS web UI → **System → Shell** (or SSH in as admin)
2. Create the sudoers file:
   ```
   vi /etc/sudoers.d/healthcheck
   ```
3. Add this single line:
   ```
   healthcheck ALL=(root) NOPASSWD: /sbin/zpool list *
   ```
4. Save and verify syntax:
   ```
   visudo -c -f /etc/sudoers.d/healthcheck
   ```

### 1.3 Configure NFS exports

Two hosts need access to the same backup dataset — the PBS Mini PC needs read-write to store backups, and the Debian VM needs read-only to run rclone.

1. TrueNAS web UI → **Shares → Unix (NFS) → Add**
2. Path: `/mnt/tank/backups/proxmox-backups`
3. Add network for PBS Mini PC: `192.168.178.142/32` — permission: **Read-Write**
4. Add network for Debian VM: `192.168.178.141/32` — permission: **Read-Only**
5. Enable the NFS service if not already running: **Services → NFS → Start**

> ⚠️ The same dataset path is mounted at different local paths on each client: `/mnt/truenas-backup` on PBS (RW) and `/mnt/truenas` on Debian VM (RO). Both resolve to the same TrueNAS export.

### 1.4 Add the Debian VM SSH public key

> This step is completed after Step 4.5 where the key is generated on the Debian VM. Come back here then.

1. After generating the key on the Debian VM, copy the public key:
   ```bash
   cat /root/.ssh/id_ed25519_truenas.pub
   ```
2. On TrueNAS: **Credentials → Local Users → healthcheck → Edit**
3. Paste the public key into the **SSH Public Keys** field
4. Save

---

## Step 2 — PBS Mini PC `192.168.178.142`

One script runs on the PBS Mini PC. Its job is to write a timestamped success marker to the TrueNAS NFS mount after each nightly backup window closes. The Debian VM reads this marker to confirm PBS ran within the RPO window.

### 2.1 Install packages

```bash
apt update && apt install -y mailutils
```

### 2.2 Mount TrueNAS NFS

1. Create the mount point:
   ```bash
   mkdir -p /mnt/truenas-backup
   ```
2. Add to `/etc/fstab`:
   ```
   192.168.178.139:/mnt/tank/backups/proxmox-backups  /mnt/truenas-backup  nfs  rw,soft,timeo=30,retrans=3,nofail  0 0
   ```
3. Mount it:
   ```bash
   mount /mnt/truenas-backup
   ```
4. Verify it is writable:
   ```bash
   touch /mnt/truenas-backup/.test && rm /mnt/truenas-backup/.test && echo OK
   ```

### 2.3 Configure outbound mail

1. Install msmtp:
   ```bash
   apt install -y msmtp msmtp-mta
   ```
2. Create `/etc/msmtprc` — example using Fastmail:
   ```
   defaults
   auth           on
   tls            on
   tls_trust_file /etc/ssl/certs/ca-certificates.crt
   logfile        /var/log/msmtp.log

   account        homelab
   host           smtp.fastmail.com
   port           587
   from           homelab@yourdomain.com
   user           homelab@yourdomain.com
   password       YOUR_APP_PASSWORD

   account default : homelab
   ```
3. Set `/etc/aliases` so root mail goes to your real address:
   ```bash
   echo 'root: your@email.com' >> /etc/aliases && newaliases
   ```
4. Test:
   ```bash
   echo 'test from PBS' | mail -s '[HOMELAB TEST] PBS mail' root
   ```

### 2.4 Install `pbs-write-marker.sh`

1. Copy `pbs-write-marker.sh` to the host
2. Install:
   ```bash
   cp pbs-write-marker.sh /usr/local/bin/
   chmod +x /usr/local/bin/pbs-write-marker.sh
   ```
3. Test run:
   ```bash
   /usr/local/bin/pbs-write-marker.sh
   ```
4. Confirm marker was written:
   ```bash
   cat /mnt/truenas-backup/.pbs-last-success.txt
   ```

### 2.5 Install crontab entry

1. Open crontab:
   ```bash
   crontab -e
   ```
2. Add this line — runs 30 minutes after backup window closes at ~04:00:
   ```
   30 4 * * *   /usr/local/bin/pbs-write-marker.sh >> /var/log/pbs-marker.log 2>&1
   ```

> ⚠️ Adjust the time to be at least 30 minutes after your PBS backup job typically finishes. Check PBS job history to confirm the typical finish time.

---

## Step 3 — Proxmox Host `192.168.178.127`

The Proxmox host runs daily NVMe health checks and the full quarterly analytics and forensic pipeline. All these scripts stay on the Proxmox host — they are never installed on the Debian VM.

### 3.1 Install packages

```bash
apt update && apt install -y nvme-cli mailutils msmtp msmtp-mta
```

### 3.2 Configure outbound mail

Same process as PBS Mini PC (Step 2.3). Repeat on this host.

1. Create `/etc/msmtprc` with your SMTP relay settings
2. Set root alias:
   ```bash
   echo 'root: your@email.com' >> /etc/aliases && newaliases
   ```
3. Test:
   ```bash
   echo 'test from Proxmox' | mail -s '[HOMELAB TEST] Proxmox mail' root
   ```

### 3.3 Create forensic history directories

```bash
mkdir -p /root/forensic-history/metrics
mkdir -p /root/forensic-history/dumps
```

### 3.4 Install `forensic-config.sh`

This file is sourced by four other scripts. It must go to `/root/`, not `/usr/local/bin/`.

1. Copy `forensic-config.sh` to the host
2. Install:
   ```bash
   cp forensic-config.sh /root/forensic-config.sh
   chmod +x /root/forensic-config.sh
   ```

> ⚠️ If you want to change any threshold (e.g. capacity warning level), edit `/root/forensic-config.sh`. All four analytics scripts pick up the change automatically.

### 3.5 Install all Proxmox scripts

1. Copy all Proxmox scripts to the host
2. Install:
   ```bash
   cp check-nvme-health.sh collect-metrics.sh score-metrics.sh \
      anomaly-detection.sh predict-capacity.sh forensic-dump.sh \
      update-integrity-chain.sh verify-integrity.sh \
      quarterly-report.sh prune-forensic-history.sh \
      /usr/local/bin/

   chmod +x /usr/local/bin/check-nvme-health.sh \
            /usr/local/bin/collect-metrics.sh \
            /usr/local/bin/score-metrics.sh \
            /usr/local/bin/anomaly-detection.sh \
            /usr/local/bin/predict-capacity.sh \
            /usr/local/bin/forensic-dump.sh \
            /usr/local/bin/update-integrity-chain.sh \
            /usr/local/bin/verify-integrity.sh \
            /usr/local/bin/quarterly-report.sh \
            /usr/local/bin/prune-forensic-history.sh
   ```

### 3.6 Test NVMe health check

1. Run manually and confirm output:
   ```bash
   /usr/local/bin/check-nvme-health.sh
   ```
2. Expected output:
   ```
   [NVME-HEALTH] PASS -- wear=X%, container partition OK, rpool ONLINE
   ```

> ⚠️ If it fails, read the error message. Most common causes: `nvme-cli` not installed, `/var/lib/docker` not mounted, rpool name different from `rpool`.

### 3.7 Run first forensic dump and integrity chain

1. Run forensic dump — this also initialises the integrity chain:
   ```bash
   /usr/local/bin/forensic-dump.sh
   ```
2. Confirm the dump was written:
   ```bash
   ls -la /root/forensic-history/dumps/
   ```
3. Confirm the integrity chain was created with append-only flag:
   ```bash
   lsattr /root/forensic-history/dumps/integrity-chain.txt
   ```
4. You should see the `a` flag:
   ```
   -----a-------- /root/forensic-history/dumps/integrity-chain.txt
   ```
5. If the `a` flag is missing, set it manually:
   ```bash
   chattr +a /root/forensic-history/dumps/integrity-chain.txt
   ```

### 3.8 Install Proxmox crontab entries

1. Open crontab:
   ```bash
   crontab -e
   ```
2. Add all Proxmox entries:

| Schedule | Script | Frequency |
|---|---|---|
| `0 6 * * *` | `check-nvme-health.sh` | Daily |
| `0 5 1 1,4,7,10 *` | `forensic-dump.sh` | Quarterly |
| `30 5 1 1,4,7,10 *` | `update-integrity-chain.sh` | Quarterly |
| `0 6 1 1,4,7,10 *` | `collect-metrics.sh` | Quarterly |
| `0 7 1 1,4,7,10 *` | `score-metrics.sh` | Quarterly |
| `5 7 1 1,4,7,10 *` | `anomaly-detection.sh` | Quarterly |
| `10 7 1 1,4,7,10 *` | `predict-capacity.sh` | Quarterly |
| `0 8 1 1,4,7,10 *` | `quarterly-report.sh` | Quarterly |
| `0 4 1 1 *` | `prune-forensic-history.sh` | Annual |

---

## Step 4 — Debian VM (primary monitoring host) `192.168.178.141`

This is the most involved host. It runs the Tier-0 evaluator, all backup-related scripts, the daily report, and the restore verification tool. All steps must be completed in order.

### 4.1 Install packages

```bash
apt update && apt install -y chrony nut-client msmtp msmtp-mta mailutils rclone
```

### 4.2 Configure NTP to sync from Proxmox

This VM must sync time from the Proxmox host (`192.168.178.127`), not from external NTP servers. This ensures all backup timestamps and PBS snapshot ordering are consistent across the infrastructure.

1. Edit `/etc/chrony.conf`:
   ```bash
   vi /etc/chrony.conf
   ```
2. Add or replace the server line with:
   ```
   server 192.168.178.127 iburst prefer
   makestep 1.0 3
   ```
3. Restart chrony:
   ```bash
   systemctl restart chronyd
   ```
4. Verify it is syncing from Proxmox (look for `*` next to the Proxmox IP):
   ```bash
   chronyc sources
   ```
5. Confirm tracking output shows Proxmox as the reference:
   ```bash
   chronyc tracking
   ```

### 4.3 Configure outbound mail

Same process as previous hosts. Repeat here.

1. Create `/etc/msmtprc` with your SMTP relay settings
2. Set root alias:
   ```bash
   echo 'root: your@email.com' >> /etc/aliases && newaliases
   ```
3. Test:
   ```bash
   echo 'test from Debian VM' | mail -s '[HOMELAB TEST] Debian mail' root
   ```

### 4.4 Mount TrueNAS NFS (read-only)

1. Create mount point:
   ```bash
   mkdir -p /mnt/truenas
   ```
2. Add to `/etc/fstab`:
   ```
   192.168.178.139:/mnt/tank/backups/proxmox-backups  /mnt/truenas  nfs  ro,soft,timeo=30,retrans=3,nofail  0 0
   ```
3. Mount it:
   ```bash
   mount /mnt/truenas
   ```
4. Verify it is responsive:
   ```bash
   ls /mnt/truenas
   ```

### 4.5 Generate SSH key for TrueNAS healthcheck user

1. Generate the key:
   ```bash
   ssh-keygen -t ed25519 -f /root/.ssh/id_ed25519_truenas -N ""
   ```
2. Accept TrueNAS host key into known_hosts:
   ```bash
   ssh-keyscan 192.168.178.139 >> /root/.ssh/known_hosts
   ```
3. Display the public key — copy this for Step 1.4:
   ```bash
   cat /root/.ssh/id_ed25519_truenas.pub
   ```
4. Now complete **Step 1.4** on TrueNAS (add this key to healthcheck user)
5. Then verify the SSH connection works:
   ```bash
   ssh -i /root/.ssh/id_ed25519_truenas healthcheck@192.168.178.139 "sudo zpool list -H -o health"
   ```
6. Expected output:
   ```
   ONLINE
   ```

### 4.6 Install the boot inhibit service

This systemd service sets `/var/run/backup_inhibit` at every boot, before cron starts. The system state is UNKNOWN after a reboot until `monitor-backups.sh` runs and clears it. This is correct fail-closed behaviour.

1. Copy `tier0-boot-inhibit.service` to the host
2. Install:
   ```bash
   cp tier0-boot-inhibit.service /etc/systemd/system/
   ```
3. Enable and start:
   ```bash
   systemctl daemon-reload
   systemctl enable --now tier0-boot-inhibit.service
   ```
4. Verify the inhibit file was created:
   ```bash
   cat /var/run/backup_inhibit
   ```
5. Expected output shows the reboot timestamp and reason:
   ```
   REBOOT 2025-01-01T07:00:00+00:00 -- state UNKNOWN, awaiting Tier-0 verification
   ```

### 4.7 Install all Debian VM scripts

1. Copy all Debian VM scripts to the host
2. Install:
   ```bash
   cp monitor-backups.sh check-nfs-health.sh dump-databases.sh \
      backup-filen-rclone.sh homelab-daily-report.sh test-restore.sh \
      /usr/local/bin/

   chmod +x /usr/local/bin/monitor-backups.sh \
            /usr/local/bin/check-nfs-health.sh \
            /usr/local/bin/dump-databases.sh \
            /usr/local/bin/backup-filen-rclone.sh \
            /usr/local/bin/homelab-daily-report.sh \
            /usr/local/bin/test-restore.sh
   ```

### 4.8 Configure rclone for Filen Cloud

1. Create rclone config:
   ```bash
   rclone config
   ```
2. Add a new remote named `filen`:
   ```
   Type: webdav
   URL:  https://webdav.filen.io
   Vendor: other
   User: YOUR_FILEN_EMAIL
   Password: (use rclone obscure <your_password>)
   ```
3. Add a second remote named `filen-crypt`:
   ```
   Type: crypt
   Remote: filen:homelab-backup
   Filename encryption: standard
   Directory name encryption: true
   Password: (use rclone obscure <your_crypt_passphrase>)
   Password2 (salt): (use rclone obscure <your_salt>)
   ```
4. Test the connection:
   ```bash
   rclone lsd filen-crypt:
   ```

> 🔴 **CRITICAL — Back up `rclone.conf` immediately**  
> The `rclone.conf` file contains your Filen credentials AND your crypt passphrase. If you lose the passphrase, your entire cloud backup is permanently unreadable — even if the files still exist on Filen. Back this file up to at least two independent offline locations (e.g. encrypted USB + printed copy in a safe).  
> Location: `/root/.config/rclone/rclone.conf`

### 4.9 Run `monitor-backups.sh` for the first time

This clears the boot inhibit if all Tier-0 checks pass. If it fails, read the error message carefully — it will tell you exactly which check failed.

1. Run manually:
   ```bash
   /usr/local/bin/monitor-backups.sh
   ```
2. If all checks pass, the inhibit file is cleared:
   ```bash
   ls /var/run/backup_inhibit   # should return: No such file or directory
   ```
3. If it fails, read the output and fix the reported issue before continuing

> ⚠️ The most common first-run failures are:
> - NTP not yet syncing from Proxmox (wait 1-2 minutes after chrony restart)
> - TrueNAS SSH not yet configured (complete Step 1.4 first)
> - PBS marker not yet written (run `pbs-write-marker.sh` on PBS host manually)
> - Filen marker not yet written (run `backup-filen-rclone.sh` manually once)

### 4.10 Install Debian VM crontab entries

1. Open crontab:
   ```bash
   crontab -e
   ```
2. Add all Debian VM entries:

| Schedule | Script | Frequency |
|---|---|---|
| `*/5 * * * *` | `monitor-backups.sh` | Every 5 min |
| `15 * * * *` | `check-nfs-health.sh` | Hourly |
| `0 2 * * *` | `dump-databases.sh` | Nightly 02:00 |
| `0 3 * * 0` | `backup-filen-rclone.sh` | Weekly Sunday 03:00 |
| `0 7 * * *` | `homelab-daily-report.sh` | Daily 07:00 |

---

## Step 5 — Verification (run from Debian VM)

Work through each check in order. Do not proceed to the next check until the current one passes.

### 5.1 Confirm Tier-0 is VERIFIED

1. Run `monitor-backups.sh` manually:
   ```bash
   /usr/local/bin/monitor-backups.sh
   ```
2. Expected last line:
   ```
   [TIER-0] VERIFIED -- all authorities passed
   ```
3. Confirm inhibit is gone:
   ```bash
   ls /var/run/backup_inhibit   # should say: No such file or directory
   ```
4. Confirm heartbeat was written:
   ```bash
   cat /var/run/tier0_heartbeat
   ```

### 5.2 Confirm NFS health check passes

1. Run:
   ```bash
   /usr/local/bin/check-nfs-health.sh
   ```
2. Expected last line:
   ```
   [NFS-HEALTH] PASS -- /mnt/truenas is mounted, responsive, source=192.168.178.139:...
   ```

### 5.3 Run a database dump manually

1. Trigger a test dump:
   ```bash
   /usr/local/bin/dump-databases.sh
   ```
2. Confirm dumps were written to TrueNAS:
   ```bash
   ls -la /mnt/truenas/db-dumps/
   ```
3. Expected files: `pg-paperless-YYYY-MM-DD.dump`, `pg-immich-YYYY-MM-DD.dump`, `redis-paperless-YYYY-MM-DD.rdb`

### 5.4 Run rclone upload manually (first time)

This creates the Filen marker that `monitor-backups.sh` requires to pass the cloud backup recency check.

1. Run (this may take a while on first upload):
   ```bash
   /usr/local/bin/backup-filen-rclone.sh
   ```
2. Confirm the marker was written:
   ```bash
   cat /var/log/filen-last-success.txt
   ```

### 5.5 Confirm daily report sends correctly

1. Run manually:
   ```bash
   /usr/local/bin/homelab-daily-report.sh
   ```
2. Check your email inbox for: `[HOMELAB DAILY] OK | ...`
3. Check the log:
   ```bash
   cat /var/log/homelab-daily-$(date +%F).log
   ```

### 5.6 Run NVMe health check on Proxmox

SSH to the Proxmox host for this step.

1. SSH to Proxmox:
   ```bash
   ssh root@192.168.178.127
   ```
2. Run:
   ```bash
   /usr/local/bin/check-nvme-health.sh
   ```
3. Expected output:
   ```
   [NVME-HEALTH] PASS -- wear=X%, container partition OK, rpool ONLINE
   ```

### 5.7 Run the monthly restore test

1. Back on the Debian VM — run manually and review all output:
   ```bash
   sudo /usr/local/bin/test-restore.sh 2>&1 | tee /var/log/restore-test-$(date +%F).log
   ```
2. All lines should print `[PASS]`
3. Specifically confirm:
   - Filen remote listing returns files (not empty)
   - PBS archive files are found and non-zero sized
   - `pg_restore --list` succeeds for paperless and immich dumps

### 5.8 Reboot test

1. Reboot the Debian VM:
   ```bash
   reboot
   ```
2. After reboot, confirm inhibit was set by the boot service:
   ```bash
   cat /var/run/backup_inhibit   # should show REBOOT + timestamp
   ```
3. Wait up to 5 minutes for `monitor-backups.sh` cron to run, then:
   ```bash
   ls /var/run/backup_inhibit   # should now be gone
   ```
4. Check `tier0.log` to confirm it ran and passed:
   ```bash
   tail -5 /var/log/tier0.log
   ```

---

## Ongoing Operations

### Daily — automatic

- **07:00** Daily health report email sent from Debian VM
- If any check failed overnight, a reactive alert email arrived earlier
- Check your inbox: one `[HOMELAB DAILY]` email per day is normal

### Monthly — manual

1. Run the restore verification from the Debian VM:
   ```bash
   sudo /usr/local/bin/test-restore.sh 2>&1 | tee /var/log/restore-test-$(date +%F).log
   ```
2. Review the output — all checks must show `[PASS]`
3. If any check fails, investigate and fix before relying on that backup

### Quarterly — automatic, but review the email

- You will receive a `[HOMELAB QUARTERLY]` report email from Proxmox
- Review the risk score, anomaly section, and capacity prediction
- If prediction shows < 4 quarters to CRITICAL, plan storage expansion now

### Manually verifying the integrity chain

1. SSH to Proxmox:
   ```bash
   ssh root@192.168.178.127
   ```
2. Run:
   ```bash
   sudo /usr/local/bin/verify-integrity.sh
   ```
3. All entries should show `[OK]`
4. `MISSING` entries after a prune are expected — that is normal and correct

---

## Email Subject Reference

| Subject prefix | Meaning | Action needed |
|---|---|---|
| `[HOMELAB DAILY] OK` | All checks passed | None — routine |
| `[HOMELAB DAILY] DEGRADED` | Warnings, no failures | Review and monitor |
| `[HOMELAB DAILY] ACTION REQUIRED` | One or more checks failed | Investigate immediately |
| `[HOMELAB TIER-0 FAILED]` | Tier-0 failed mid-cycle | Investigate immediately |
| `[HOMELAB NFS FAIL]` | NFS mount unresponsive | Check TrueNAS and network |
| `[HOMELAB NVME FAIL]` | NVMe SMART or capacity | Check drive health |
| `[HOMELAB NVME WARN]` | NVMe wear approaching | Plan drive replacement |
| `[HOMELAB DB DUMP FAIL]` | Database dump failed | Check Docker containers |
| `[HOMELAB FILEN FAIL]` | rclone upload failed | Check rclone config + Filen |
| `[HOMELAB PBS MARKER FAIL]` | PBS marker not written | Check PBS backup job |
| `[HOMELAB RISK HIGH/CRITICAL]` | Metrics crossed threshold | Review quarterly report |
| `[HOMELAB ANOMALY]` | Sudden metric spike | Review anomaly log |
| `[HOMELAB QUARTERLY]` | Quarterly report | Review and file |
| `[HOMELAB INTEGRITY FAIL]` | Chain update failed | Check dump directory |
| `[HOMELAB PRUNE]` | Annual pruning ran | Confirm expected files removed |

---

## Pending Items

These items require physical hardware changes and cannot be completed during initial software setup.

### UPS / NUT configuration

The UPS check in `monitor-backups.sh` is currently non-blocking because NUT is not yet configured. To activate it:

1. Physically connect the UPS USB cable to the Proxmox host
2. On Proxmox, identify the UPS driver:
   ```bash
   nut-scanner -U
   ```
3. Configure NUT server on Proxmox: `/etc/nut/nut.conf`, `ups.conf`, `upsd.conf`, `upsd.users`, `upsmon.conf`
4. Start NUT services:
   ```bash
   systemctl enable --now nut-server nut-monitor
   ```
5. Configure NUT client on Debian VM: `/etc/nut/nut.conf` (`MODE=netclient`), `upsmon.conf`
6. In `monitor-backups.sh`: uncomment the blocking UPS check and set `UPS_NAME`
7. In `homelab-daily-report.sh`: the UPS section activates automatically once `upsc` works

> ⚠️ Until this is complete, you will receive periodic `[HOMELAB UPS PENDING]` emails from `monitor-backups.sh`. These are informational only and do not indicate a system failure.

---

*End of Deployment Guide*
