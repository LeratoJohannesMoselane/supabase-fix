#!/bin/bash
# =============================================================================
# Setup Weekly Backup Cron + Systemd Timer for Supabase
# Usage:
#   ./scripts/setup_weekly_backup.sh sony
#   ./scripts/setup_weekly_backup.sh --all                    # ALL projects
#   ./scripts/setup_weekly_backup.sh sony --day 0 --hour 3 --keep-days 28 --s3 s3://bucket/sony
#   ./scripts/setup_weekly_backup.sh --all --s3 s3://bucket/all --systemd
#   ./scripts/setup_weekly_backup.sh sony --systemd           # systemd timer
#   ./scripts/setup_weekly_backup.sh --all --uninstall        # remove all backup jobs
#   ./scripts/setup_weekly_backup.sh sony --uninstall
#
# Default: Weekly on Sunday at 03:00 AM
# =============================================================================
set -e

PROJECT="sony"
DAY_OF_WEEK=0   # 0=Sunday, 1=Monday... 7=Sunday (both)
HOUR=3
MINUTE=0
KEEP_DAYS=28
S3_DEST=""
USE_SYSTEMD=false
UNINSTALL=false
ALL_MODE=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all|-a|all) ALL_MODE=true; PROJECT="all"; shift;;
    --day) DAY_OF_WEEK="$2"; shift 2;;
    --hour) HOUR="$2"; shift 2;;
    --minute) MINUTE="$2"; shift 2;;
    --keep-days) KEEP_DAYS="$2"; shift 2;;
    --keep-count) KEEP_COUNT="$2"; shift 2;;
    --s3) S3_DEST="$2"; shift 2;;
    --systemd) USE_SYSTEMD=true; shift;;
    --cron) USE_SYSTEMD=false; shift;;
    --uninstall|--remove) UNINSTALL=true; shift;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# //;s/^#//'
      exit 0
      ;;
    --*) echo "Unknown: $1"; exit 1;;
    *) PROJECT="$1"; shift;;
  esac
done

# If project is literally "all" string, set all mode
if [ "$PROJECT" = "all" ]; then ALL_MODE=true; fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS_DIR="$ROOT_DIR/projects"

if $ALL_MODE; then
  PROJECT_PATH="$PROJECTS_DIR"
  BACKUP_DIR="$PROJECTS_DIR"
  WEEKLY_DIR="$PROJECTS_DIR/backups_weekly_all"
  CRON_CMD="$ROOT_DIR/scripts/backup_all_projects.sh --verify ${S3_DEST:+--s3 $S3_DEST}"
  LOG_FILE="$PROJECTS_DIR/_all_backups.log"
  CRON_LINE="$MINUTE $HOUR * * $DAY_OF_WEEK BACKUP_KEEP_DAYS=$KEEP_DAYS $CRON_CMD >> $PROJECTS_DIR/_all_backups.log 2>&1"
else
  PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"
  BACKUP_DIR="$PROJECT_PATH/backups"
  WEEKLY_DIR="$BACKUP_DIR/weekly"
  LOG_FILE="$BACKUP_DIR/weekly_backup.log"
  CRON_CMD="$ROOT_DIR/scripts/weekly_backup.sh $PROJECT --verify ${S3_DEST:+--s3 $S3_DEST}"
  CRON_LINE="$MINUTE $HOUR * * $DAY_OF_WEEK BACKUP_KEEP_DAYS=$KEEP_DAYS $CRON_CMD >> $BACKUP_DIR/weekly_backup.log 2>&1"
fi

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if ! $ALL_MODE && [ ! -d "$PROJECT_PATH" ]; then
  echo "Project not found: $PROJECT_PATH"
  echo "Available:"
  ls -1 "$ROOT_DIR/projects/" 2>/dev/null || echo "  none"
  echo "Use --all to backup all projects"
  exit 1
fi

if $ALL_MODE && [ ! -d "$PROJECTS_DIR" ]; then
  mkdir -p "$PROJECTS_DIR"
fi

mkdir -p "$WEEKLY_DIR" 2>/dev/null || mkdir -p "$BACKUP_DIR"

if $UNINSTALL; then
  if $ALL_MODE; then
    info "Uninstalling weekly backup for ALL projects"
    crontab -l 2>/dev/null | grep -v "backup_all_projects.sh" | grep -v "weekly_backup.sh --all" | crontab - || true
    ok "Cron for ALL removed"
    if [ -f "/etc/systemd/system/supabase-backup-all.timer" ]; then
      sudo systemctl disable --now supabase-backup-all.timer || true
      sudo rm -f /etc/systemd/system/supabase-backup-all.service /etc/systemd/system/supabase-backup-all.timer
      sudo systemctl daemon-reload
      ok "Systemd timer supabase-backup-all removed"
    fi
    # Also remove per-project timers? optionally
    for svc in /etc/systemd/system/supabase-backup@*.timer; do
      [ -f "$svc" ] || continue
      echo "Found $svc – remove? (y/N)"
      read -r ans
      if [[ "$ans" =~ ^[Yy]$ ]]; then
        base=$(basename "$svc")
        sudo systemctl disable --now "$base" || true
        sudo rm -f "/etc/systemd/system/${base%.timer}.service" "$svc"
      fi
    done
    sudo systemctl daemon-reload 2>/dev/null || true
  else
    info "Uninstalling weekly backup for $PROJECT"
    crontab -l 2>/dev/null | grep -v "weekly_backup.sh $PROJECT" | crontab - || true
    ok "Cron for $PROJECT removed"
    if [ -f "/etc/systemd/system/supabase-backup@$PROJECT.timer" ]; then
      sudo systemctl disable --now "supabase-backup@$PROJECT.timer" || true
      sudo rm -f "/etc/systemd/system/supabase-backup@$PROJECT.service" "/etc/systemd/system/supabase-backup@$PROJECT.timer"
      sudo systemctl daemon-reload
      ok "Systemd timer removed"
    fi
  fi
  exit 0
fi

echo ""
if $ALL_MODE; then
  echo "=== Setup Weekly Backup for ALL PROJECTS ==="
  DISCOVERED=()
  for d in "$PROJECTS_DIR"/*; do [ -d "$d" ] || continue; [ -f "$d/docker-compose.yml" ] && DISCOVERED+=("$(basename $d)"); done
  echo "Found projects: ${DISCOVERED[*]:-none}"
else
  echo "=== Setup Weekly Backup for $PROJECT ==="
  echo "Project: $PROJECT"
fi
echo "Schedule: Weekly, day $DAY_OF_WEEK (0=Sun) at $HOUR:$MINUTE"
echo "Keep: $KEEP_DAYS days"
echo "S3: ${S3_DEST:-none (local only)}"
echo "Method: $( $USE_SYSTEMD && echo systemd || echo cron )"
echo "Backup dir: $WEEKLY_DIR"
echo "Log: $LOG_FILE"
echo ""

chmod +x "$ROOT_DIR/scripts/"*.sh

if $USE_SYSTEMD; then
  if $ALL_MODE; then
    info "Creating systemd service supabase-backup-all (for ALL projects)..."
    SERVICE_FILE="/etc/systemd/system/supabase-backup-all.service"
    TIMER_FILE="/etc/systemd/system/supabase-backup-all.timer"
    declare -A DAY_MAP=( [0]="Sun" [7]="Sun" [1]="Mon" [2]="Tue" [3]="Wed" [4]="Thu" [5]="Fri" [6]="Sat" )
    WEEKDAY="${DAY_MAP[$DAY_OF_WEEK]:-Sun}"

    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Weekly Supabase Backup for ALL projects
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$ROOT_DIR
Environment=BACKUP_KEEP_DAYS=$KEEP_DAYS
ExecStart=$ROOT_DIR/scripts/backup_all_projects.sh --verify ${S3_DEST:+--s3 $S3_DEST}
StandardOutput=append:$PROJECTS_DIR/_all_backups.log
StandardError=append:$PROJECTS_DIR/_all_backups.log
EOF

    sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Weekly Backup Timer for ALL Supabase projects

[Timer]
OnCalendar=$WEEKDAY *-*-* $HOUR:$MINUTE:00
Persistent=true
RandomizedDelaySec=900
Unit=supabase-backup-all.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now supabase-backup-all.timer
    ok "Systemd timer supabase-backup-all enabled"
    systemctl list-timers | grep supabase || sudo systemctl list-timers | grep supabase || true
    echo ""
    echo "Check:"
    echo "  systemctl status supabase-backup-all.timer"
    echo "  journalctl -u supabase-backup-all.service --since today"
    echo "  sudo systemctl start supabase-backup-all.service"
  else
    info "Creating systemd service supabase-backup@$PROJECT..."
    SERVICE_FILE="/etc/systemd/system/supabase-backup@$PROJECT.service"
    TIMER_FILE="/etc/systemd/system/supabase-backup@$PROJECT.timer"
    declare -A DAY_MAP=( [0]="Sun" [7]="Sun" [1]="Mon" [2]="Tue" [3]="Wed" [4]="Thu" [5]="Fri" [6]="Sat" )
    WEEKDAY="${DAY_MAP[$DAY_OF_WEEK]:-Sun}"

    sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Weekly Supabase Backup for %i
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$USER
WorkingDirectory=$ROOT_DIR
Environment=BACKUP_KEEP_DAYS=$KEEP_DAYS
ExecStart=$ROOT_DIR/scripts/weekly_backup.sh %i --verify ${S3_DEST:+--s3 $S3_DEST}
StandardOutput=append:$BACKUP_DIR/weekly_backup.log
StandardError=append:$BACKUP_DIR/weekly_backup.log
EOF

    sudo tee "$TIMER_FILE" > /dev/null <<EOF
[Unit]
Description=Weekly Backup Timer for Supabase %i

[Timer]
OnCalendar=$WEEKDAY *-*-* $HOUR:$MINUTE:00
Persistent=true
RandomizedDelaySec=900
Unit=supabase-backup@%i.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now "supabase-backup@$PROJECT.timer"
    ok "Systemd timer enabled"
    systemctl list-timers | grep supabase || sudo systemctl list-timers | grep supabase || true
  fi
else
  info "Installing cron job..."
  if $ALL_MODE; then
    (crontab -l 2>/dev/null | grep -v "backup_all_projects.sh"; echo "$CRON_LINE") | crontab -
    ok "Cron for ALL installed"
    crontab -l | grep -E "backup_all|weekly_backup" || true
  else
    (crontab -l 2>/dev/null | grep -v "weekly_backup.sh $PROJECT"; echo "$CRON_LINE") | crontab -
    ok "Cron for $PROJECT installed"
    crontab -l | grep -E "weekly_backup|$PROJECT" || true
  fi
fi

# Test run prompt
echo ""
if $ALL_MODE; then
  read -p "Run a test backup now for ALL projects? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    "$ROOT_DIR/scripts/backup_all_projects.sh" --verify ${S3_DEST:+--s3 $S3_DEST}
  fi
else
  read -p "Run a test backup now for $PROJECT? (y/N): " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    "$ROOT_DIR/scripts/weekly_backup.sh" "$PROJECT" --verify ${S3_DEST:+--s3 $S3_DEST}
  fi
fi

echo ""
if $ALL_MODE; then
  ok "Weekly backup for ALL projects setup complete"
  echo "Backups go to: projects/<each>/backups/weekly/"
  echo "Manifest: projects/backups_weekly_all/"
  echo "Global log: $PROJECTS_DIR/_all_backups.log"
  echo "To uninstall: ./scripts/setup_weekly_backup.sh --all --uninstall"
else
  ok "Weekly backup setup complete for $PROJECT"
  echo "Backups will go to: $WEEKLY_DIR"
  echo "Log: $LOG_FILE"
  echo "To uninstall: ./scripts/setup_weekly_backup.sh $PROJECT --uninstall"
fi
