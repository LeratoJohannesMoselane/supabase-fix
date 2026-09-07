#!/bin/bash
# =============================================================================
# Weekly Backup for Supabase Projects (Production Ready)
# Usage: ./scripts/weekly_backup.sh sony [--verify] [--s3 s3://my-bucket/backups]
#
# Features:
# - pg_dumpall + storage tar + env tar
# - gzip + sha256 checksums
# - Retention: keep 4 weekly (28 days default) + optional count limit
# - Verifies gzip integrity
# - Optional S3/R2 upload (aws cli)
# - Cron-friendly logging
# - Lock file to prevent overlapping runs
# =============================================================================
set -e

PROJECT=${1:-}
VERIFY=false
S3_DEST=""
KEEP_DAYS=${BACKUP_KEEP_DAYS:-28}   # 4 weeks default for weekly
KEEP_COUNT=${BACKUP_KEEP_COUNT:-8}  # keep max 8 backups regardless of age
ALL_MODE=false

# Parse flags and detect --all
ARGS=("$@")
for arg in "$@"; do
  case "$arg" in
    --all|-a|all) ALL_MODE=true ;;
    --verify) VERIFY=true ;;
    --s3) S3_NEXT=true ;;
    s3://*)
      if [ "$S3_NEXT" = true ]; then
        S3_DEST="$arg"
        S3_NEXT=false
      else
        S3_DEST="$arg"
      fi
      ;;
  esac
done
# Handle --s3 <dest> as separate args
for i in "${!ARGS[@]}"; do
  if [[ "${ARGS[$i]}" == "--s3" && -n "${ARGS[$((i+1))]}" ]]; then
    S3_DEST="${ARGS[$((i+1))]}"
  fi
done

# Default project handling
if [ -z "$PROJECT" ] || [[ "$PROJECT" == --* ]] || [ "$PROJECT" = "all" ]; then
  if $ALL_MODE; then
    PROJECT="all"
  else
    # If no project given, default to all if projects dir has >1 project, else sony
    # For backwards compat, default to sony if exists, else all
    PROJECT="sony"
  fi
fi
# Strip flags from PROJECT if PROJECT looks like a flag
if [[ "$PROJECT" == --* ]]; then PROJECT="sony"; fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# If --all, delegate to backup_all_projects.sh
if $ALL_MODE || [ "$PROJECT" = "all" ] || [ "$PROJECT" = "--all" ]; then
  echo "[INFO] --all mode: backing up ALL projects via backup_all_projects.sh"
  exec "$ROOT_DIR/scripts/backup_all_projects.sh" ${VERIFY:+--verify} ${S3_DEST:+--s3 $S3_DEST}
  exit $?
fi
PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"
TIMESTAMP=$(date +%F_%H%M%S)
DATESTAMP=$(date +%Y-%m-%d)
BACKUP_DIR="$PROJECT_PATH/backups"
WEEKLY_DIR="$BACKUP_DIR/weekly"
LOCK_FILE="/tmp/supabase_backup_${PROJECT}.lock"
LOG_FILE="$BACKUP_DIR/weekly_backup.log"

# Colors for non-cron
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; CYAN=''; NC=''
fi

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }
info() { log "${CYAN}[INFO]${NC} $1"; }
ok() { log "${GREEN}[OK]${NC} $1"; }
warn() { log "${YELLOW}[WARN]${NC} $1"; }
fail() { log "${RED}[FAIL]${NC} $1"; }

# Lock to prevent overlapping backups
if [ -f "$LOCK_FILE" ]; then
  PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
  if kill -0 "$PID" 2>/dev/null; then
    fail "Backup already running (PID $PID) lock $LOCK_FILE, aborting"
    exit 1
  else
    warn "Stale lock found, removing"
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Checks
if [ ! -d "$PROJECT_PATH" ]; then
  fail "Project not found: $PROJECT_PATH"
  ls -1 "$ROOT_DIR/projects/" 2>/dev/null || true
  exit 1
fi

mkdir -p "$WEEKLY_DIR"
touch "$LOG_FILE"

info "=== Weekly Backup Start: $PROJECT at $TIMESTAMP ==="
info "Project path: $PROJECT_PATH"
info "Backup dir: $WEEKLY_DIR"
info "Keep: ${KEEP_DAYS} days, max ${KEEP_COUNT} files"
if [ -n "$S3_DEST" ]; then info "S3 dest: $S3_DEST"; fi

# Helper: check docker
docker_ok=true
if ! command -v docker >/dev/null 2>&1; then
  warn "docker not found, DB backup will be skipped (ok on dev machine)"
  docker_ok=false
elif ! docker ps | grep -q "${PROJECT}-db"; then
  warn "Container ${PROJECT}-db not running, DB backup may fail"
fi

# 1. DB dump
DB_FILE="$WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_pg_dumpall.sql.gz"
CHECKSUM_FILE="$WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_checksums.sha256"
info "Dumping PostgreSQL pg_dumpall -> $DB_FILE"

if $docker_ok; then
  TMP_SQL="/tmp/${PROJECT}_${TIMESTAMP}_pg_dumpall.sql"
  if docker exec -t ${PROJECT}-db pg_dumpall -U postgres > "$TMP_SQL" 2>>"$LOG_FILE"; then
    gzip -c "$TMP_SQL" > "$DB_FILE"
    rm -f "$TMP_SQL"
    sha256sum "$DB_FILE" > "$CHECKSUM_FILE"
    ok "DB backup: $(du -h "$DB_FILE" | cut -f1) -> $DB_FILE"
  else
    warn "DB dump failed, is ${PROJECT}-db running? docker ps:"
    docker ps | grep -E "${PROJECT}|supabase" | tee -a "$LOG_FILE" || true
    rm -f "$TMP_SQL" || true
  fi
else
  # Create placeholder for testing without docker
  echo "-- Placeholder backup - no docker in this env - $(date)" | gzip > "$DB_FILE"
  sha256sum "$DB_FILE" > "$CHECKSUM_FILE"
  warn "Created placeholder DB backup (no docker)"
fi

# 2. Storage backup
STORAGE_FILE="$WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_storage.tar.gz"
info "Backing up storage -> $STORAGE_FILE"
if [ -d "$PROJECT_PATH/volumes/storage" ] && [ "$(ls -A $PROJECT_PATH/volumes/storage 2>/dev/null)" ]; then
  tar -czf "$STORAGE_FILE" -C "$PROJECT_PATH" volumes/storage 2>>"$LOG_FILE" && \
    { sha256sum "$STORAGE_FILE" >> "$CHECKSUM_FILE"; ok "Storage backup: $(du -h "$STORAGE_FILE" | cut -f1)"; } || warn "Storage backup failed"
else
  info "No storage data or empty, skipping storage tar (file backend empty is normal)"
fi

# 2b. Studio SQL snippets (volumes/snippets/snippets.json - not part of the DB dump)
SNIPPETS_FILE="$WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_snippets.tar.gz"
if [ -f "$PROJECT_PATH/volumes/snippets/snippets.json" ]; then
  info "Backing up Studio snippets -> $SNIPPETS_FILE"
  tar -czf "$SNIPPETS_FILE" -C "$PROJECT_PATH" volumes/snippets 2>>"$LOG_FILE" && \
    { sha256sum "$SNIPPETS_FILE" >> "$CHECKSUM_FILE"; ok "Snippets backup: $(du -h "$SNIPPETS_FILE" | cut -f1)"; } || \
    warn "Snippets backup failed"
else
  info "No volumes/snippets/snippets.json yet - nothing to back up (Studio snippets are created on first save)"
fi

# 3. Config backup (env + credentials + compose) – ENCRYPTED CONSIDERATION
CONFIG_FILE="$WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_config.tar.gz"
info "Backing up config (.env, .credentials, docker-compose.yml) -> $CONFIG_FILE"
if [ -f "$PROJECT_PATH/.env" ]; then
  tar -czf "$CONFIG_FILE" -C "$PROJECT_PATH" --exclude='volumes/db/data' .env .credentials docker-compose.yml docker-compose.override.yml 2>/dev/null || \
  tar -czf "$CONFIG_FILE" -C "$PROJECT_PATH" .env docker-compose.yml 2>>"$LOG_FILE" || warn "Config backup partial"
  if [ -f "$CONFIG_FILE" ]; then
    sha256sum "$CONFIG_FILE" >> "$CHECKSUM_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Config backup: $(du -h "$CONFIG_FILE" | cut -f1) (600 perms)"
  fi
else
  warn ".env not found, skipping config backup"
fi

# 4. Verify
if $VERIFY || [ "${BACKUP_VERIFY:-true}" = "true" ]; then
  info "Verifying backups integrity..."
  # gzip -t
  for f in "$DB_FILE" "$STORAGE_FILE" "$CONFIG_FILE"; do
    if [ -f "$f" ]; then
      if gzip -t "$f" 2>>"$LOG_FILE"; then
        ok "Verified gzip: $(basename $f)"
      else
        fail "Corrupt gzip: $f"
      fi
    fi
  done
  # sha256
  if [ -f "$CHECKSUM_FILE" ]; then
    if sha256sum -c "$CHECKSUM_FILE" >>"$LOG_FILE" 2>&1; then
      ok "Checksums OK: $CHECKSUM_FILE"
    else
      fail "Checksum mismatch! Check $CHECKSUM_FILE"
    fi
  fi
fi

# 5. Retention cleanup
info "Retention: deleting backups older than $KEEP_DAYS days"
find "$WEEKLY_DIR" -type f -name "${PROJECT}_*_pg_dumpall.sql.gz" -mtime +$KEEP_DAYS -print -delete | tee -a "$LOG_FILE" || true
find "$WEEKLY_DIR" -type f -name "${PROJECT}_*_storage.tar.gz" -mtime +$KEEP_DAYS -print -delete | tee -a "$LOG_FILE" || true
find "$WEEKLY_DIR" -type f -name "${PROJECT}_*_snippets.tar.gz" -mtime +$KEEP_DAYS -print -delete | tee -a "$LOG_FILE" || true
find "$WEEKLY_DIR" -type f -name "${PROJECT}_*_config.tar.gz" -mtime +$KEEP_DAYS -print -delete | tee -a "$LOG_FILE" || true
find "$WEEKLY_DIR" -type f -name "${PROJECT}_*_checksums.sha256" -mtime +$KEEP_DAYS -print -delete | tee -a "$LOG_FILE" || true

# Also keep max count (newest $KEEP_COUNT)
info "Retention: keeping max $KEEP_COUNT newest DB backups"
ls -1t "$WEEKLY_DIR"/${PROJECT}_*_pg_dumpall.sql.gz 2>/dev/null | tail -n +$((KEEP_COUNT+1)) | while read -r old; do
  info "Deleting old by count: $old"
  rm -f "$old" "${old%.sql.gz}_storage.tar.gz" "${old%.sql.gz}_config.tar.gz" "${old%.sql.gz}_checksums.sha256" 2>/dev/null || true
  # more robust: delete matching timestamp
  TS=$(basename "$old" | sed -E "s/${PROJECT}_//; s/_pg_dumpall.sql.gz//")
  rm -f "$WEEKLY_DIR/${PROJECT}_${TS}"* 2>/dev/null || true
done

# 6. S3 upload (optional)
if [ -n "$S3_DEST" ]; then
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws cli not installed, skipping S3 upload. Install: pip install awscli or apt install awscli"
  else
    info "Uploading weekly backups to S3: $S3_DEST"
    # Upload only today's files
    aws s3 cp "$WEEKLY_DIR/" "$S3_DEST/$PROJECT/$DATESTAMP/" --recursive --include "${PROJECT}_${TIMESTAMP}*" --exclude "*" 2>&1 | tee -a "$LOG_FILE" && \
      ok "S3 upload done" || warn "S3 upload failed"
  fi
fi

# Summary
info "=== Weekly Backup Complete: $PROJECT ==="
ls -lh "$WEEKLY_DIR" | tail -n 20 | tee -a "$LOG_FILE"
du -sh "$WEEKLY_DIR" | tee -a "$LOG_FILE"
echo ""
echo "Restore DB:"
echo "  gunzip -c $WEEKLY_DIR/${PROJECT}_${TIMESTAMP}_pg_dumpall.sql.gz | docker exec -i ${PROJECT}-db psql -U postgres"
echo ""
echo "Verify:"
echo "  sha256sum -c $CHECKSUM_FILE"
echo "  gzip -t $DB_FILE"

ok "Done. Log: $LOG_FILE"
