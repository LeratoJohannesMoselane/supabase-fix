#!/bin/bash
# Quickstart - shortest path to Supabase DB on Ubuntu
# Usage: ./quickstart.sh [project-name] [port]
# Example: ./quickstart.sh demo 8000
set -e
PROJECT=${1:-my-supabase}
PORT=${2:-8000}
echo ">>> Quickstart: $PROJECT on $PORT"
./deploy.sh "$PROJECT" "$PORT" --non-interactive --yes --skip-deps 2>&1 || {
  echo "[INFO] First try failed, provisioning deps then retrying..."
  chmod +x scripts/ubuntu-provision.sh
  ./scripts/ubuntu-provision.sh
  ./deploy.sh "$PROJECT" "$PORT" --non-interactive --yes
}
