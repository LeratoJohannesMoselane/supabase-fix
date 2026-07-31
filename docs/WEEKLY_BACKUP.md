# Weekly Backup for Supabase – ALL Projects

This guide sets up **automatic weekly backups** for ALL your self-hosted Supabase projects (auto-discovers `projects/*`). Works for `sony` and every future project you create.

We provide 2 methods: **cron (simple)** and **systemd timer (recommended for Ubuntu)**.

Backups include per project:
- PostgreSQL full dump (`pg_dumpall` → `*.sql.gz`)
- Storage files (`volumes/storage` → `*.tar.gz`) if using file backend
- Config (`.env`, `.credentials`, `docker-compose.yml` → `*.tar.gz`, chmod 600)
- SHA256 checksums + gzip verification
- Global manifest + combined log

Retention: default **28 days / 8 backups** for weekly = 4 weeks kept. Customize via `BACKUP_KEEP_DAYS` and `BACKUP_KEEP_COUNT`.

## NEW: Backup ALL Projects (Recommended)

If `sony` won't be your only project, use `--all`:

```bash
# Backup ALL projects now
./scripts/backup_all_projects.sh --verify
./scripts/weekly_backup.sh --all --verify          # alias
make weekly-backup-all                              # Makefile

# Setup weekly cron for ALL (Sunday 3am)
./scripts/setup_weekly_backup.sh --all
make setup-weekly-backup-all

# Systemd for ALL
./scripts/setup_weekly_backup.sh --all --systemd
make setup-weekly-backup-all-systemd

# ALL + S3 offsite
./scripts/setup_weekly_backup.sh --all --s3 s3://my-bucket/supabase-all --day 0 --hour 3
./scripts/backup_all_projects.sh --s3 s3://my-bucket/supabase-all --verify
```

Auto-discovery: every folder in `projects/` with `docker-compose.yml` is backed up. New projects you create tomorrow are automatically included – no need to re-setup cron.

Outputs:
```
projects/
├── sony/backups/weekly/sony_2025-08-03_030000_*.gz
├── myapp/backups/weekly/myapp_2025-08-03_030000_*.gz
├── another/backups/weekly/another_*.gz
├── _all_backups.log                    # global log
└── backups_weekly_all/2025-08-03_030000_MANIFEST.txt
```

---

## Quick Setup – Weekly Backup for `sony`

### Option 1: One-liner (Cron, Sunday 3am)

On Ubuntu server:

```bash
cd ~/supabase-fix

# Make executable
chmod +x scripts/*.sh

# Setup weekly cron – Sunday 03:00, keep 28 days, local only
./scripts/setup_weekly_backup.sh sony

# Or with S3 upload
./scripts/setup_weekly_backup.sh sony --s3 s3://my-bucket/sony-backups --keep-days 28
```

This installs crontab line:
```cron
0 3 * * 0 BACKUP_KEEP_DAYS=28 /home/ubuntu/supabase-fix/scripts/weekly_backup.sh sony --verify >> /home/ubuntu/supabase-fix/projects/sony/backups/weekly_backup.log 2>&1
```

### Option 2: Systemd Timer (Recommended for Ubuntu 22.04/24.04)

More reliable than cron (handles reboots, logs via journalctl):

```bash
./scripts/setup_weekly_backup.sh sony --systemd --day 0 --hour 3 --keep-days 28
```

Check:
```bash
systemctl status supabase-backup@sony.timer
systemctl list-timers | grep sony
journalctl -u supabase-backup@sony.service --since today
sudo systemctl start supabase-backup@sony.service  # run now
```

### Option 3: Manual Cron Entry

If you prefer to edit crontab yourself:

```bash
crontab -e
# Add:
# Weekly Sony – Sunday 2am
0 2 * * 0 /home/ubuntu/supabase-fix/scripts/weekly_backup.sh sony --verify >> /home/ubuntu/supabase-fix/projects/sony/backups/weekly_backup.log 2>&1

# Weekly Sony + S3 upload – Sunday 3am
0 3 * * 0 /home/ubuntu/supabase-fix/scripts/weekly_backup.sh sony --s3 s3://my-bucket/sony --verify >> /home/ubuntu/supabase-fix/projects/sony/backups/weekly_backup.log 2>&1
```

---

## Running Backups Manually

```bash
# Weekly backup now with verification
./scripts/weekly_backup.sh sony --verify

# Weekly + S3
./scripts/weekly_backup.sh sony --s3 s3://my-bucket/sony-backups --verify

# Old simple daily backup (still works)
./scripts/backup.sh sony
./scripts/backup.sh sony --cron
```

Outputs to:
```
projects/sony/backups/weekly/
├── sony_2025-08-03_030000_pg_dumpall.sql.gz
├── sony_2025-08-03_030000_storage.tar.gz (if has files)
├── sony_2025-08-03_030000_config.tar.gz (env + compose)
└── sony_2025-08-03_030000_checksums.sha256
```

Log:
```
projects/sony/backups/weekly_backup.log
```

---

## S3 / R2 / MinIO Setup

1. Install AWS CLI:
```bash
sudo apt install awscli -y
# or pipx install awscli
aws configure
# enter ACCESS_KEY, SECRET, region
```

For R2 / MinIO, add endpoint:
```bash
# ~/.aws/config
[profile r2]
endpoint_url = https://<ACCOUNTID>.r2.cloudflarestorage.com
```

Then:
```bash
./scripts/weekly_backup.sh sony --s3 s3://my-bucket/supabase/sony
```

The script does:
```bash
aws s3 cp weekly/ s3://my-bucket/supabase/sony/YYYY-MM-DD/ --recursive --include "sony_TIMESTAMP*"
```

For R2:
```bash
aws s3 cp weekly/ s3://my-bucket/sony/ --recursive --endpoint-url https://<id>.r2.cloudflarestorage.com
```

---

## Restore From Weekly Backup

### Restore DB (full)

```bash
PROJECT=sony
BACKUP_FILE=projects/$PROJECT/backups/weekly/${PROJECT}_2025-08-03_030000_pg_dumpall.sql.gz

# Verify first
gzip -t $BACKUP_FILE
sha256sum -c projects/$PROJECT/backups/weekly/${PROJECT}_2025-08-03_030000_checksums.sha256

# Restore – will overwrite DB!
gunzip -c $BACKUP_FILE | docker exec -i ${PROJECT}-db psql -U postgres

# Or restore to clean project
cd projects/$PROJECT
docker compose up -d db
sleep 5
gunzip -c ../backups/weekly/...sql.gz | docker exec -i ${PROJECT}-db psql -U postgres
docker compose up -d
```

### Restore Storage Files

```bash
tar -xzf projects/sony/backups/weekly/sony_2025-08-03_030000_storage.tar.gz -C projects/sony/
# or
tar -xzf projects/sony/backups/weekly/sony_2025-08-03_030000_storage.tar.gz -C /tmp/ && cp -r /tmp/volumes/storage/* projects/sony/volumes/storage/
```

### Restore Config (.env)

```bash
tar -xzf projects/sony/backups/weekly/sony_2025-08-03_030000_config.tar.gz -C /tmp/
# careful – compare first!
diff -u /tmp/.env projects/sony/.env | head
```

---

## Monitoring & Alerts

Check last backup age:

```bash
ls -lt projects/sony/backups/weekly/*.sql.gz | head
find projects/sony/backups/weekly -name "*.sql.gz" -mtime +8 -print  # older than 8 days = missed weekly
```

Add healthcheck to cron (optional email / Slack via webhook):

```bash
# In weekly_backup.sh log, grep for FAIL
# Example simple alert – add after backup line in cron:
# && curl -f https://hc-ping.com/your-uuid || echo "backup failed" | mail -s "Sony backup FAILED" admin@example.com
```

Systemd will log to journalctl – you can set `OnFailure=` to trigger alert service.

---

## Cron Schedule Examples

```cron
# Every Sunday 3am (weekly default)
0 3 * * 0 /path/to/weekly_backup.sh sony --verify >> log 2>&1

# Every Monday 2am
0 2 * * 1 /path/to/weekly_backup.sh sony --verify >> log 2>&1

# Twice monthly – 1st and 15th at 3am
0 3 1,15 * * /path/to/weekly_backup.sh sony --verify >> log 2>&1

# Daily at 2am for critical DB (still uses weekly dir but daily)
0 2 * * * /path/to/backup.sh sony --cron >> log 2>&1

# Weekly + keep 60 days
0 3 * * 0 BACKUP_KEEP_DAYS=60 /path/to/weekly_backup.sh sony --verify >> log 2>&1
```

---

## Uninstall Weekly Backup

```bash
./scripts/setup_weekly_backup.sh sony --uninstall   # removes cron and systemd timer

# Manual:
crontab -l | grep -v "weekly_backup.sh sony" | crontab -
sudo systemctl disable --now supabase-backup@sony.timer
sudo rm /etc/systemd/system/supabase-backup@sony.*
sudo systemctl daemon-reload
```

---

## TL;DR for Sony on Ubuntu

```bash
cd ~/supabase-fix
./scripts/setup_weekly_backup.sh sony --day 0 --hour 3 --keep-days 28
# answer y to test run
ls -lh projects/sony/backups/weekly/
cat projects/sony/backups/weekly_backup.log
```

Done – your Sony Supabase now has **automatic weekly backups every Sunday 3am**, kept for 4 weeks, verified via checksums.

Want monthly offsite to S3? Add `--s3 s3://my-bucket/sony --systemd` and `aws configure`.
