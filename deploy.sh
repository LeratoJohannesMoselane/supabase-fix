#!/bin/bash
# ==============================================================================
# Supabase Easy Deploy for Ubuntu Server
# One-command workflow to create & run a Supabase DB on Ubuntu
#
# Usage:
#   ./deploy.sh [project-name] [base-port] [options]
#
# Examples:
#   ./deploy.sh myapp 8000                           # localhost dev
#   ./deploy.sh myapp 8000 --domain api.example.com --protocol https
#   ./deploy.sh myapp --non-interactive --yes        # fully automated
#   ./deploy.sh myapp 8000 --user admin --pass StrongPass123!
#
# Options:
#   --domain DOMAIN        Custom domain (default: localhost)
#   --protocol PROTOCOL    http or https (default: http, https if domain != localhost)
#   --user USER            Dashboard username (default: supabase)
#   --pass PASS            Dashboard password (generated random if not set)
#   --non-interactive      No prompts, use defaults
#   --yes -y               Auto-confirm overwrite of existing project
#   --open-firewall        Auto-open ports with ufw
#   --skip-deps            Skip apt/docker install checks
#   --help -h              Show help
#
# After deploy, access:
#   Studio: http://<server-ip>:<STUDIO_PORT>  (default base 8000 -> studio 10000)
#   API:    http://<server-ip>:<KONG_HTTP_PORT> (default 8000)
#   DB:     postgres://postgres:<password>@localhost:<POSTGRES_PORT>
# ==============================================================================

set -e

# Defaults
PROJECT_NAME="${1:-my-supabase}"
BASE_PORT="${2:-8000}"
DOMAIN="localhost"
PROTOCOL="http"
DASHBOARD_USER="supabase"
DASHBOARD_PASS=""
NON_INTERACTIVE=false
AUTO_YES=false
OPEN_FIREWALL=false
SKIP_DEPS=false
EXTRA_ARGS=()

# Parse all args (support both positional and flags)
# Re-parse to extract flags even if project/port were positional
ARGS=("$@")
# Reset positional parsing
PROJECT_NAME="my-supabase"
BASE_PORT="8000"
POSITIONAL=()
i=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2;;
    --protocol) PROTOCOL="$2"; shift 2;;
    --user) DASHBOARD_USER="$2"; shift 2;;
    --pass|--password) DASHBOARD_PASS="$2"; shift 2;;
    --non-interactive) NON_INTERACTIVE=true; shift;;
    --yes|-y) AUTO_YES=true; shift;;
    --open-firewall) OPEN_FIREWALL=true; shift;;
    --skip-deps) SKIP_DEPS=true; shift;;
    --help|-h)
      sed -n '2,40p' "$0" | sed 's/^# //;s/^#//'
      exit 0
      ;;
    --*) echo "Unknown option: $1"; exit 1;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
# Assign positional back
if [ ${#POSITIONAL[@]} -ge 1 ]; then PROJECT_NAME="${POSITIONAL[0]}"; fi
if [ ${#POSITIONAL[@]} -ge 2 ]; then BASE_PORT="${POSITIONAL[1]}"; fi

# Auto-set protocol to https if domain is not localhost and protocol not explicitly set to http
if [ "$DOMAIN" != "localhost" ] && [ "$PROTOCOL" = "http" ]; then
  # Check if user explicitly passed --protocol, if not, use https for custom domains
  for arg in "${ARGS[@]}"; do
    if [[ "$arg" == "--protocol" ]]; then PROTOCOL_SET=true; fi
  done
  if [ "$PROTOCOL_SET" != "true" ]; then PROTOCOL="https"; fi
fi

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECTS_DIR="$ROOT_DIR/projects"
PROJECT_PATH="$PROJECTS_DIR/$PROJECT_NAME"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

banner() {
cat <<'BANNER'
   _____                       __                  ______ _
  / ___/__  ______  ____  ____/ /_  ____ _________/_  __/ /_  __
  \__ \/ / / / __ \/ __ \/ __  / / / / / / / ___/ / / / __ \/ /
 ___/ / /_/ / /_/ / /_/ / /_/ / /_/ / /_/ (__  ) / / / / / / /
/____/\__,_/ .___/\____/\__,_/\__,_/\__,_/____/ /_/ /_/ /_/_/
          /_/
  Easy Deploy for Ubuntu
BANNER
}

check_ubuntu() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ "$ID" != "ubuntu" ] && [ "$ID_LIKE" != *"ubuntu"* ] && [ "$ID" != "debian" ]; then
      warn "This script is optimized for Ubuntu, but you're on $ID. Continuing anyway..."
    else
      success "OS: $PRETTY_NAME"
    fi
  fi
}

install_deps() {
  if [ "$SKIP_DEPS" = true ]; then
    info "Skipping deps install (--skip-deps)"
    return
  fi

  info "Checking system dependencies..."

  # Docker
  if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker..."
    sudo apt-get update -y
    sudo apt-get install -y ca-certificates curl gnupg lsb-release python3-venv python3-pip openssl git ufw
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
    if [ -f /etc/apt/keyrings/docker.gpg ]; then
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -y
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || sudo apt-get install -y docker.io docker-compose-plugin
    else
      sudo apt-get install -y docker.io docker-compose-plugin
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker $USER || true
    success "Docker installed"
  else
    success "Docker found: $(docker --version)"
  fi

  # Docker compose v2 check
  if ! docker compose version >/dev/null 2>&1; then
    fail "docker compose plugin missing. Run: sudo apt install docker-compose-plugin"
  fi

  # Python
  if ! command -v python3 >/dev/null 2>&1; then
    sudo apt-get install -y python3 python3-venv python3-pip
  fi

  # Python venv & deps
  if [ ! -d "$ROOT_DIR/.venv" ]; then
    info "Creating python venv..."
    python3 -m venv "$ROOT_DIR/.venv"
  fi
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.venv/bin/activate"
  pip install -q -r "$ROOT_DIR/requirements.txt"
  success "Python deps ready"

  # Make scripts executable
  chmod +x "$ROOT_DIR"/*.py "$ROOT_DIR"/*.sh "$ROOT_DIR/bash/"*.sh 2>/dev/null || true
}

generate_password_if_needed() {
  if [ -z "$DASHBOARD_PASS" ]; then
    if command -v openssl >/dev/null 2>&1; then
      DASHBOARD_PASS=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-16)
    else
      DASHBOARD_PASS=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
    fi
    info "Generated dashboard password: $DASHBOARD_PASS (save this!)"
  fi
}

create_project() {
  mkdir -p "$PROJECTS_DIR"

  if [ -d "$PROJECT_PATH" ]; then
    if [ "$AUTO_YES" = true ] || [ "$NON_INTERACTIVE" = true ]; then
      warn "Removing existing project $PROJECT_PATH (--yes)"
      rm -rf "$PROJECT_PATH"
    else
      echo -e "${YELLOW}Project $PROJECT_PATH already exists.${NC}"
      read -rp "Remove and recreate? (y/N): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "$PROJECT_PATH"
      else
        fail "Aborted. Use --yes to overwrite or choose another name."
      fi
    fi
  fi

  info "Creating Supabase project: $PROJECT_NAME (base port $BASE_PORT, domain $DOMAIN)"

  # Activate venv
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.venv/bin/activate" 2>/dev/null || true

  cd "$ROOT_DIR"

  # Feed answers to supabase_manager.py create which prompts for localhost
  set +e
  if [ "$DOMAIN" = "localhost" ]; then
    info "Config: localhost, CORS *"
    printf "Y\n" | python3 supabase_manager.py create "$PROJECT_NAME" --base-port "$BASE_PORT"
    CREATE_EXIT=$?
  else
    info "Config: $PROTOCOL://$DOMAIN"
    # Prompts: Is this setup for localhost? (Y/N):, Enter protocol, Enter domain
    printf "N\n%s\n%s\n" "$PROTOCOL" "$DOMAIN" | python3 supabase_manager.py create "$PROJECT_NAME" --base-port "$BASE_PORT"
    CREATE_EXIT=$?
  fi
  set -e

  if [ $CREATE_EXIT -ne 0 ] || [ ! -d "$PROJECT_PATH" ]; then
    fail "Failed to create project at $PROJECT_PATH"
  fi

  # Ensure volume dirs
  mkdir -p "$PROJECT_PATH/volumes/logs" "$PROJECT_PATH/volumes/db/data" "$PROJECT_PATH/volumes/storage"

  success "Project files created"

  # Copy init files if needed (setup_secure_supabase does this, but ensure)
  if [ -f "$ROOT_DIR/_supabase.sql" ]; then cp "$ROOT_DIR/_supabase.sql" "$PROJECT_PATH/volumes/db/_supabase.sql" 2>/dev/null || true; fi
  if [ -f "$ROOT_DIR/init_analytics_schema.sql" ]; then cp "$ROOT_DIR/init_analytics_schema.sql" "$PROJECT_PATH/volumes/db/logs.sql" 2>/dev/null || true; fi
  if [ -f "$ROOT_DIR/sample_security_policies.sql" ]; then cp "$ROOT_DIR/sample_security_policies.sql" "$PROJECT_PATH/" 2>/dev/null || true; fi
  if [ -f "$ROOT_DIR/security_checklist.md" ]; then cp "$ROOT_DIR/security_checklist.md" "$PROJECT_PATH/" 2>/dev/null || true; fi

  # Generate secure keys
  info "Generating secure JWT & API keys..."
  python3 "$ROOT_DIR/generate_keys.py" --env-file "$PROJECT_PATH/.env"

  # Update dashboard creds
  info "Setting dashboard credentials: $DASHBOARD_USER / ****"
  python3 "$ROOT_DIR/update_env_credentials.py" --project-name "$PROJECT_NAME" --username "$DASHBOARD_USER" --password "$DASHBOARD_PASS"

  # If custom domain, patch .env URLs (generator only patches CORS, not .env)
  if [ "$DOMAIN" != "localhost" ]; then
    info "Patching .env for custom domain $PROTOCOL://$DOMAIN"
    STUDIO_P=$(grep "^STUDIO_PORT=" "$PROJECT_PATH/.env" | cut -d'=' -f2 | tr -d '"' || echo "3000")
    KONG_P=$(grep "^KONG_HTTP_PORT=" "$PROJECT_PATH/.env" | cut -d'=' -f2 | tr -d '"' || echo "$BASE_PORT")
    # Update SUPABASE_PUBLIC_URL and API_EXTERNAL_URL to custom domain
    sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=${PROTOCOL}://${DOMAIN}:${KONG_P}|" "$PROJECT_PATH/.env" || echo "SUPABASE_PUBLIC_URL=${PROTOCOL}://${DOMAIN}:${KONG_P}" >> "$PROJECT_PATH/.env"
    sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=${PROTOCOL}://${DOMAIN}:${KONG_P}|" "$PROJECT_PATH/.env" || echo "API_EXTERNAL_URL=${PROTOCOL}://${DOMAIN}:${KONG_P}" >> "$PROJECT_PATH/.env"
    # If user wants SITE_URL to be custom domain too, patch (default keep localhost studio)
    # We set SITE_URL to custom domain's studio port if provided
    if grep -q "^SITE_URL=" "$PROJECT_PATH/.env"; then
      sed -i "s|^SITE_URL=.*|SITE_URL=${PROTOCOL}://${DOMAIN}:${STUDIO_P}|" "$PROJECT_PATH/.env"
    fi
    success "Patched URLs to $PROTOCOL://$DOMAIN"
  fi

  success "Keys & credentials configured"
}

start_project() {
  info "Starting Supabase stack..."
  cd "$PROJECT_PATH"
  docker compose up -d
  info "Waiting 12s for services to bootstrap..."
  sleep 12

  # Show status
  docker compose ps || true

  # Extract ports
  STUDIO_PORT=$(grep "^STUDIO_PORT=" .env | cut -d'=' -f2 | tr -d '"' || echo "3000")
  KONG_HTTP_PORT=$(grep "^KONG_HTTP_PORT=" .env | cut -d'=' -f2 | tr -d '"' || echo "$BASE_PORT")
  POSTGRES_PORT=$(grep "^POSTGRES_PORT=" .env | cut -d'=' -f2 | tr -d '"' || echo "5432")
  POOLER_PORT=$(grep "^POOLER_PROXY_PORT_TRANSACTION=" .env | cut -d'=' -f2 | tr -d '"' || echo "6543")
  ANON_KEY=$(grep "^ANON_KEY=" .env | cut -d'=' -f2- | tr -d '"' || echo "")
  SERVICE_KEY=$(grep "^SERVICE_ROLE_KEY=" .env | cut -d'=' -f2- | tr -d '"' || echo "")

  SERVER_IP=$(hostname -I | awk '{print $1}' || echo "localhost")
  # Try to get public IP
  PUBLIC_IP=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null || echo "$SERVER_IP")

  cat <<EOF

${GREEN}==================================================${NC}
${GREEN}  Supabase Deployment Complete!${NC}
${GREEN}==================================================${NC}

Project: ${PROJECT_NAME}
Path:    ${PROJECT_PATH}

Access URLs (local):
  Studio Dashboard: http://localhost:${STUDIO_PORT}
  API Endpoint:     http://localhost:${KONG_HTTP_PORT}
  PostgreSQL:       postgresql://postgres:***@localhost:${POSTGRES_PORT}/postgres

Access URLs (from network):
  Studio: http://$SERVER_IP:${STUDIO_PORT}
  API:    http://$SERVER_IP:${KONG_HTTP_PORT}

Public (if firewall open):
  Studio: http://$PUBLIC_IP:${STUDIO_PORT}
  API:    http://$PUBLIC_IP:${KONG_HTTP_PORT}

Credentials:
  Dashboard User: ${DASHBOARD_USER}
  Dashboard Pass: ${DASHBOARD_PASS}
  Saved in: ${PROJECT_PATH}/.credentials

Database Direct:
  Host: localhost (or $SERVER_IP)
  Port: $POSTGRES_PORT
  User: postgres
  Pass: (see .env POSTGRES_PASSWORD)
  Database: postgres

API Keys (client):
  ANON_KEY: ${ANON_KEY:0:40}...
  SERVICE_ROLE_KEY: ${SERVICE_KEY:0:40}... (keep secret!)

${YELLOW}Next steps:${NC}
  1. Save credentials: cat ${PROJECT_PATH}/.credentials
  2. Check logs: cd ${PROJECT_PATH} && docker compose logs -f
  3. Connect psql: docker exec -it ${PROJECT_NAME}-db psql -U postgres
  4. See sample RLS: cat ${PROJECT_PATH}/sample_security_policies.sql

Management:
  cd ${PROJECT_PATH}
  docker compose ps               # status
  docker compose logs -f studio   # logs
  docker compose down             # stop (keeps data)
  docker compose down -v          # STOP + WIPE data (danger!)

Backup:
  ${ROOT_DIR}/scripts/backup.sh ${PROJECT_NAME}

EOF

  # Save credentials file
  cat > "$PROJECT_PATH/.credentials" <<CRED
# Supabase Credentials - ${PROJECT_NAME} - $(date)
PROJECT_NAME=${PROJECT_NAME}
STUDIO_PORT=${STUDIO_PORT}
KONG_HTTP_PORT=${KONG_HTTP_PORT}
POSTGRES_PORT=${POSTGRES_PORT}
POOLER_PORT=${POOLER_PORT}
DASHBOARD_USERNAME=${DASHBOARD_USER}
DASHBOARD_PASSWORD=${DASHBOARD_PASS}
STUDIO_URL=http://localhost:${STUDIO_PORT}
API_URL=http://localhost:${KONG_HTTP_PORT}
POSTGRES_URL=postgresql://postgres:\$(grep POSTGRES_PASSWORD .env | cut -d'=' -f2)@localhost:${POSTGRES_PORT}/postgres
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_KEY}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DOMAIN=${DOMAIN}
PROTOCOL=${PROTOCOL}
CRED
  chmod 600 "$PROJECT_PATH/.credentials"
  success "Credentials saved to $PROJECT_PATH/.credentials"
}

setup_firewall() {
  if [ "$OPEN_FIREWALL" != true ]; then
    return
  fi
  if ! command -v ufw >/dev/null 2>&1; then
    warn "ufw not found, skipping firewall"
    return
  fi
  info "Opening firewall ports with ufw..."
  STUDIO_PORT=$(grep "^STUDIO_PORT=" "$PROJECT_PATH/.env" | cut -d'=' -f2 || echo "3000")
  KONG_HTTP_PORT=$(grep "^KONG_HTTP_PORT=" "$PROJECT_PATH/.env" | cut -d'=' -f2 || echo "$BASE_PORT")
  POSTGRES_PORT=$(grep "^POSTGRES_PORT=" "$PROJECT_PATH/.env" | cut -d'=' -f2 || echo "5432")
  POOLER_PORT=$(grep "^POOLER_PROXY_PORT_TRANSACTION=" "$PROJECT_PATH/.env" | cut -d'=' -f2 || echo "6543")

  sudo ufw allow "$STUDIO_PORT"/tcp || true
  sudo ufw allow "$KONG_HTTP_PORT"/tcp || true
  # Don't auto-open postgres to public by default unless explicitly wanted
  # sudo ufw allow "$POSTGRES_PORT"/tcp || true
  sudo ufw allow 22/tcp || true
  success "UFW rules added for $STUDIO_PORT, $KONG_HTTP_PORT (postgres not opened for security)"
}

create_helper_scripts() {
  mkdir -p "$ROOT_DIR/scripts"
  # Only create backup.sh if more complete version doesn't exist
  if [ ! -f "$ROOT_DIR/scripts/backup.sh" ] || [ $(wc -c < "$ROOT_DIR/scripts/backup.sh") -lt 500 ]; then
    cat > "$ROOT_DIR/scripts/backup.sh" <<'BACKUP'
#!/bin/bash
PROJECT=${1:-my-supabase}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"
if [ ! -d "$PROJECT_PATH" ]; then echo "Project $PROJECT not found at $PROJECT_PATH"; exit 1; fi
BACKUP_DIR="$PROJECT_PATH/backups"
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F_%H%M%S)
echo "[*] Backing up DB for $PROJECT..."
docker exec -t ${PROJECT}-db pg_dumpall -U postgres > "$BACKUP_DIR/${PROJECT}_${STAMP}_pg_dumpall.sql" || { echo "pg_dump failed - is DB running?"; exit 1; }
echo "[*] Backing up storage..."
tar -czf "$BACKUP_DIR/${PROJECT}_${STAMP}_storage.tar.gz" -C "$PROJECT_PATH" volumes/storage 2>/dev/null || echo "No storage dir or empty"
echo "[OK] Backup saved to $BACKUP_DIR/"
ls -lh "$BACKUP_DIR" | tail -n 20
BACKUP
    chmod +x "$ROOT_DIR/scripts/backup.sh"
  fi

  # Health check
  cat > "$ROOT_DIR/scripts/healthcheck.sh" <<'HEALTH'
#!/bin/bash
PROJECT=${1:-my-supabase}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
PROJECT_PATH="$ROOT_DIR/projects/$PROJECT"
if [ ! -d "$PROJECT_PATH" ]; then echo "Project $PROJECT not found"; exit 1; fi
cd "$PROJECT_PATH"
echo "=== $PROJECT status ==="
docker compose ps
echo ""
echo "=== Health ==="
docker compose exec -T db pg_isready -U postgres || echo "DB not ready"
KPORT=$(grep "^KONG_HTTP_PORT=" .env | cut -d'=' -f2 | tr -d '"' || echo "8000")
curl -sf http://localhost:${KPORT}/ || echo "API checking... (curl localhost:$KPORT failed, may still be booting)"
echo ""
echo "Studio: http://localhost:$(grep STUDIO_PORT .env | cut -d'=' -f2)"
echo "API: http://localhost:$KPORT"
HEALTH
  chmod +x "$ROOT_DIR/scripts/healthcheck.sh"
}

main() {
  banner
  echo -e "${CYAN}Project:${NC} $PROJECT_NAME"
  echo -e "${CYAN}Base Port:${NC} $BASE_PORT"
  echo -e "${CYAN}Domain:${NC} $PROTOCOL://$DOMAIN"
  echo -e "${CYAN}Dashboard:${NC} $DASHBOARD_USER"
  echo ""

  check_ubuntu
  install_deps
  generate_password_if_needed
  create_project
  start_project
  setup_firewall
  create_helper_scripts

  echo ""
  success "Done! Your Supabase DB is live."
  echo -e "Run ${YELLOW}cat $PROJECT_PATH/.credentials${NC} to see keys"
}

main "$@"
