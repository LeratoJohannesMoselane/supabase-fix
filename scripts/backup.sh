#!/bin/bash
# Simple backup for Supabase projects
# Usage: ./scripts/backup.sh [project-name] [--cron]
# Backups go to projects/<project>/backups/
set -e

PROJECT=${1:-my-supabase}
CRON_MODE=false
if [[ "$2" == "--cron" ]] || [[ "$1" == "--cron" ]]; then CRON_MODE=true; fi
# handle ./backup.sh myproj --cron or ./backup.sh --cron
if [[ "$1" == "--cron" ]]; then PROJECT=${2:-my-supabase}; CRON_MODE=true; fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"

if [ ! -d "$PROJECT_PATH" ]; then
  echo "Project not found: $PROJECT_PATH"
  echo "Available projects:"
  ls -1 "$ROOT_DIR/projects/" 2>/dev/null || echo "  (none)"
  exit 1
fi

BACKUP_DIR="$PROJECT_PATH/backups"
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F_%H%M%S)
KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}

echo "[*] Backup: $PROJECT at $STAMP"

# DB dump
echo "[*] Dumping PostgreSQL (pg_dumpall)..."
if docker exec -t ${PROJECT}-db pg_dumpall -U postgres > "$BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql" 2>/dev/null; then
  gzip -f "$BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql"
  echo "[OK] DB -> $BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql.gz"
  ls -lh "$BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql.gz"
else
  echo "[FAIL] DB dump failed - is ${PROJECT}-db running?"
  docker ps | grep -E "${PROJECT}|supabase"
fi

# Storage files
echo "[*] Backing up storage..."
if [ -d "$PROJECT_PATH/volumes/storage" ]; then
  tar -czf "$BACKUP_DIR/${PROJECT}_${STAMP}_storage.tar.gz" -C "$PROJECT_PATH" volumes/storage 2>/dev/null && \
    echo "[OK] Storage -> $BACKUP_DIR/${PROJECT}_${STAMP}_storage.tar.gz" || echo "[WARN] Storage backup failed"
else
  echo "[INFO] No file storage dir (might be using S3)"
fi

# Studio SQL snippets (stored as volumes/snippets/snippets.json, not in Postgres)
echo "[*] Backing up Studio snippets..."
if [ -d "$PROJECT_PATH/volumes/snippets" ]; then
  tar -czf "$BACKUP_DIR/${PROJECT}_${STAMP}_snippets.tar.gz" -C "$PROJECT_PATH" volumes/snippets 2>/dev/null && \
    echo "[OK] Snippets -> $BACKUP_DIR/${PROJECT}_${STAMP}_snippets.tar.gz" || echo "[WARN] Snippets backup failed"
else
  echo "[INFO] No volumes/snippets dir (Studio snippets not configured for this project)"
fi

# Env & credentials (secrets!)
echo "[*] Backing up .env and .credentials (encrypted?)..."
tar -czf "$BACKUP_DIR/${PROJECT}_${STAMP}_env.tar.gz" -C "$PROJECT_PATH" .env .credentials docker-compose.yml 2>/dev/null && \
  echo "[OK] Config -> $BACKUP_DIR/${PROJECT}_${STAMP}_env.tar.gz" || echo "[WARN] Config backup failed"

echo ""
echo "Backups in $BACKUP_DIR:"
ls -lh "$BACKUP_DIR" | tail -n 20

# Cleanup old backups
if [ "$KEEP_DAYS" != "0" ]; then
  echo "[*] Cleaning backups older than $KEEP_DAYS days..."
  find "$BACKUP_DIR" -type f -mtime +$KEEP_DAYS -delete -print || true
fi

echo "[OK] Done"

if $CRON_MODE; then
  echo "Cron mode - no further output"
else
  echo ""
  echo "To restore DB:"
  echo "  gunzip -c $BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql.gz | docker exec -i ${PROJECT}-db psql -U postgres"
  echo ""
  echo "To automate daily backups, add to crontab:"
  echo "  0 2 * * * $ROOT_DIR/scripts/backup.sh $PROJECT --cron >> $BACKUP_DIR/cron.log 2>&1"
fi
