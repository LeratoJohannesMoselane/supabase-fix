#!/bin/bash
# =============================================================================
# Backup ALL Supabase Projects (Weekly, Production Ready)
# Usage:
#   ./scripts/backup_all_projects.sh [--verify] [--s3 s3://bucket/backups]
#   BACKUP_KEEP_DAYS=28 ./scripts/backup_all_projects.sh --all --verify
#
# This auto-discovers every project in projects/ that has docker-compose.yml
# and backs up each one via weekly_backup.sh
# =============================================================================
set -e

VERIFY_FLAG=""
S3_DEST=""
KEEP_DAYS=${BACKUP_KEEP_DAYS:-28}
KEEP_COUNT=${BACKUP_KEEP_COUNT:-8}
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECTS_DIR="$ROOT_DIR/projects"
TIMESTAMP=$(date +%F_%H%M%S)
LOG_FILE="$PROJECTS_DIR/_all_backups.log"
GLOBAL_WEEKLY_DIR="$PROJECTS_DIR/backups_weekly_all"
LOCK_FILE="/tmp/supabase_backup_all.lock"

# Parse args
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY_FLAG="--verify";;
    --all) ;; # alias, means all – default behavior
    --s3)
      S3_NEXT=true
      ;;
    s3://*)
      if [ "$S3_NEXT" = true ]; then
        S3_DEST="$arg"
        S3_NEXT=false
      else
        S3_DEST="$arg"
      fi
      ;;
    --keep-days) KEEP_DAYS="$2"; shift;;
    --keep-count) KEEP_COUNT="$2"; shift;;
    --help|-h)
      echo "Usage: $0 [--verify] [--s3 s3://bucket/backups] [--keep-days 28]"
      echo "  Backs up ALL projects in projects/ via weekly_backup.sh"
      exit 0
      ;;
    *) ARGS+=("$arg");;
  esac
done

# Support --s3 <dest> as two args
if [[ "${ARGS[0]}" == "--s3" ]]; then S3_DEST="${ARGS[1]}"; fi

mkdir -p "$PROJECTS_DIR"
touch "$LOG_FILE"

# Lock
if [ -f "$LOCK_FILE" ]; then
  PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "unknown")
  if kill -0 "$PID" 2>/dev/null; then
    echo "[FAIL] All-backup already running PID $PID, aborting" | tee -a "$LOG_FILE"
    exit 1
  else
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

# Discover projects
DISCOVERED=()
if [ ! -d "$PROJECTS_DIR" ]; then
  echo "[WARN] No projects dir: $PROJECTS_DIR"
  exit 0
fi

for dir in "$PROJECTS_DIR"/*; do
  [ -d "$dir" ] || continue
  proj=$(basename "$dir")
  # Skip internal dirs
  if [[ "$proj" == "backups"* ]] || [[ "$proj" == "_all_backups"* ]]; then continue; fi
  if [ -f "$dir/docker-compose.yml" ] && [ -f "$dir/.env" ]; then
    DISCOVERED+=("$proj")
  elif [ -f "$dir/docker-compose.yml" ]; then
    DISCOVERED+=("$proj")
  fi
done

if [ ${#DISCOVERED[@]} -eq 0 ]; then
  echo "[INFO] No Supabase projects found in $PROJECTS_DIR" | tee -a "$LOG_FILE"
  echo "Directories:"; ls -1 "$PROJECTS_DIR" | tee -a "$LOG_FILE"
  exit 0
fi

echo "=== Backup ALL Projects: ${DISCOVERED[*]} at $(date) ===" | tee -a "$LOG_FILE"
echo "Keep: $KEEP_DAYS days, $KEEP_COUNT files, S3: ${S3_DEST:-none}" | tee -a "$LOG_FILE"

FAILED=()
SUCCESS=()
TOTAL_SIZE=0

for proj in "${DISCOVERED[@]}"; do
  echo "" | tee -a "$LOG_FILE"
  echo "--- Backing up: $proj ---" | tee -a "$LOG_FILE"
  START=$(date +%s)
  # Run weekly_backup.sh for single project
  set +e
  "$ROOT_DIR/scripts/weekly_backup.sh" "$proj" $VERIFY_FLAG ${S3_DEST:+--s3 $S3_DEST} 2>&1 | tee -a "$LOG_FILE"
  EXIT_CODE=${PIPESTATUS[0]}
  set -e
  END=$(date +%s)
  DUR=$((END-START))
  if [ $EXIT_CODE -eq 0 ]; then
    SUCCESS+=("$proj (${DUR}s)")
    echo "[OK] $proj done in ${DUR}s" | tee -a "$LOG_FILE"
  else
    FAILED+=("$proj (exit $EXIT_CODE)")
    echo "[FAIL] $proj failed exit $EXIT_CODE after ${DUR}s" | tee -a "$LOG_FILE"
  fi
done

# Optional: create combined manifest
MANIFEST="$PROJECTS_DIR/backups_weekly_all/${TIMESTAMP}_MANIFEST.txt"
mkdir -p "$PROJECTS_DIR/backups_weekly_all"
{
  echo "Backup ALL Manifest - $TIMESTAMP"
  echo "Date: $(date)"
  echo "Projects: ${DISCOVERED[*]}"
  echo "Success: ${SUCCESS[*]}"
  echo "Failed: ${FAILED[*]:-none}"
  echo ""
  echo "Disk usage per project weekly:"
  for proj in "${DISCOVERED[@]}"; do
    du -sh "$PROJECTS_DIR/$proj/backups/weekly" 2>/dev/null || echo "$proj: no weekly dir"
  done
  du -sh "$PROJECTS_DIR"/*/backups/weekly 2>/dev/null || true
  echo ""
  echo "Log: $LOG_FILE"
} | tee "$MANIFEST" | tee -a "$LOG_FILE"

# S3 for manifest if S3 configured
if [ -n "$S3_DEST" ] && command -v aws >/dev/null 2>&1; then
  echo "[INFO] Uploading manifest to $S3_DEST/_all/$TIMESTAMP/" | tee -a "$LOG_FILE"
  aws s3 cp "$MANIFEST" "$S3_DEST/_all/$TIMESTAMP/MANIFEST.txt" 2>&1 | tee -a "$LOG_FILE" || echo "[WARN] S3 manifest upload failed"
fi

echo "" | tee -a "$LOG_FILE"
echo "=== Backup ALL Summary ===" | tee -a "$LOG_FILE"
echo "Total: ${#DISCOVERED[@]} projects" | tee -a "$LOG_FILE"
echo "Success: ${#SUCCESS[@]} - ${SUCCESS[*]:-none}" | tee -a "$LOG_FILE"
echo "Failed: ${#FAILED[@]} - ${FAILED[*]:-none}" | tee -a "$LOG_FILE"
echo "Manifest: $MANIFEST" | tee -a "$LOG_FILE"
echo "Log: $LOG_FILE" | tee -a "$LOG_FILE"

# Exit with failure if any failed
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "[WARN] Some backups failed" | tee -a "$LOG_FILE"
  exit 2
else
  echo "[OK] All backups succeeded" | tee -a "$LOG_FILE"
  exit 0
fi
