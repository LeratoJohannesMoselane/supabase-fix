#!/bin/bash
# =============================================================================
# Setup Weekly Backup Cron + Systemd Timer for Supabase
# Usage:
#   ./scripts/setup_weekly_backup.sh sony
#   ./scripts/setup_weekly_backup.sh sony --day 0 --hour 3 --keep-days 28 --s3 s3://my-bucket/sony-backups
#   ./scripts/setup_weekly_backup.sh sony --systemd   # use systemd timer instead of cron
#   ./scripts/setup_weekly_backup.sh sony --uninstall # remove
#
# Default: Weekly on Sunday at 03:00 AM
# =============================================================================
set -e

PROJECT=${1:-sony}
DAY_OF_WEEK=0   # 0=Sunday, 1=Monday... 7=Sunday (both)
HOUR=3
MINUTE=0
KEEP_DAYS=28
S3_DEST=""
USE_SYSTEMD=false
UNINSTALL=false

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
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
      sed -n '2,30p' "$0" | sed 's/^# //;s/^#//'
      exit 0
      ;;
    --*) echo "Unknown: $1"; exit 1;;
    *) PROJECT="$1"; shift;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"
BACKUP_DIR="$PROJECT_PATH/backups"
WEEKLY_DIR="$BACKUP_DIR/weekly"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Project not found: $PROJECT_PATH"
  echo "Available:"
  ls -1 "$ROOT_DIR/projects/" 2>/dev/null || echo "  none"
  exit 1
fi

mkdir -p "$WEEKLY_DIR"

CRON_LINE="$MINUTE $HOUR * * $DAY_OF_WEEK BACKUP_KEEP_DAYS=$KEEP_DAYS $ROOT_DIR/scripts/weekly_backup.sh $PROJECT ${S3_DEST:+--s3 $S3_DEST} --verify >> $BACKUP_DIR/weekly_backup.log 2>&1"

if $UNINSTALL; then
  info "Uninstalling weekly backup for $PROJECT"
  # Remove cron
  crontab -l 2>/dev/null | grep -v "weekly_backup.sh $PROJECT" | crontab - || true
  ok "Cron removed"
  # Remove systemd
  if [ -f "/etc/systemd/system/supabase-backup@$PROJECT.timer" ]; then
    sudo systemctl disable --now "supabase-backup@$PROJECT.timer" || true
    sudo rm -f "/etc/systemd/system/supabase-backup@$PROJECT.service" "/etc/systemd/system/supabase-backup@$PROJECT.timer"
    sudo systemctl daemon-reload
    ok "Systemd timer removed"
  fi
  exit 0
fi

echo ""
echo "=== Setup Weekly Backup for $PROJECT ==="
echo "Project: $PROJECT"
echo "Schedule: Weekly, day $DAY_OF_WEEK (0=Sun) at $HOUR:$MINUTE"
echo "Keep: $KEEP_DAYS days"
echo "S3: ${S3_DEST:-none (local only)}"
echo "Method: $( $USE_SYSTEMD && echo systemd || echo cron )"
echo "Backup dir: $WEEKLY_DIR"
echo "Script: $ROOT_DIR/scripts/weekly_backup.sh"
echo ""

# Ensure scripts executable
chmod +x "$ROOT_DIR/scripts/"*.sh

if $USE_SYSTEMD; then
  # Systemd service + timer
  info "Creating systemd service supabase-backup@$PROJECT..."

  SERVICE_FILE="/etc/systemd/system/supabase-backup@$PROJECT.service"
  TIMER_FILE="/etc/systemd/system/supabase-backup@$PROJECT.timer"

  # Map day 0/7 Sunday -> Sun, 1->Mon etc
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
# Lock to prevent overlap already handled by script, but systemd also
LockPersonality=yes
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
  echo ""
  echo "Check timer:"
  echo "  systemctl status supabase-backup@$PROJECT.timer"
  echo "  systemctl list-timers supabase-backup@$PROJECT.timer"
  echo "  journalctl -u supabase-backup@$PROJECT.service --since today"
  echo "Run now:"
  echo "  sudo systemctl start supabase-backup@$PROJECT.service"
else
  # Cron
  info "Installing cron job..."
  # Install crontab if not exists, remove old entry for same project first
  (crontab -l 2>/dev/null | grep -v "weekly_backup.sh $PROJECT"; echo "$CRON_LINE") | crontab -
  ok "Cron installed"
  echo ""
  echo "Current crontab:"
  crontab -l | grep -E "weekly_backup|$PROJECT" || true
fi

# Test run?
echo ""
read -p "Run a test backup now for $PROJECT? (y/N): " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  "$ROOT_DIR/scripts/weekly_backup.sh" "$PROJECT" --verify ${S3_DEST:+--s3 $S3_DEST}
fi

echo ""
ok "Weekly backup setup complete for $PROJECT"
echo ""
echo "Backups will go to: $WEEKLY_DIR"
echo "Log: $BACKUP_DIR/weekly_backup.log"
echo "Restore:"
echo "  gunzip -c $WEEKLY_DIR/${PROJECT}_*_pg_dumpall.sql.gz | docker exec -i ${PROJECT}-db psql -U postgres"
echo ""
echo "To uninstall: ./scripts/setup_weekly_backup.sh $PROJECT --uninstall"
