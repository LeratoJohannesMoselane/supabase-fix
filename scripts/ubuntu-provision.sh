#!/bin/bash
# =============================================================================
# Ubuntu Server Provisioning Script for Supabase
# Installs all dependencies needed for self-hosted Supabase
#
# Usage: sudo ./scripts/ubuntu-provision.sh
#        ./scripts/ubuntu-provision.sh --check-only
# =============================================================================
set -e

CHECK_ONLY=false
if [[ "$1" == "--check-only" ]]; then CHECK_ONLY=true; fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
cat <<'BANNER'
 ____  _  _  ____   __   __ _  ____   __   ____  __  __   __ _ 
/ ___)/ )( \(  _ \ / _\ (  ( \(  __) / _\ (  _ \(  )/  \ (  ( \
\___ \) __ ( ) _ (/    \/    / ) _) /    \ )   / )((  O )/    /
(____/\_)(_/(____/\_/\_/\_)__)(____/\_/\_/(__\_)(__)\__/ \_)__)
  Ubuntu Provisioning for Supabase
BANNER
echo -e "${NC}"

check() {
  echo -n "Checking $1... "
  if eval "$2" >/dev/null 2>&1; then echo -e "${GREEN}OK${NC} - $($3)"; return 0; else echo -e "${YELLOW}MISSING${NC}"; return 1; fi
}

if $CHECK_ONLY; then
  echo "=== System Check (no install) ==="
  check "Docker" "command -v docker" "docker --version 2>&1 | head -n1"
  check "Docker Compose" "docker compose version" "docker compose version"
  check "Python3" "command -v python3" "python3 --version"
  check "Git" "command -v git" "git --version"
  check "OpenSSL" "command -v openssl" "openssl version"
  check "UFW" "command -v ufw" "ufw --version 2>&1 | head -n1"
  echo ""
  echo "Disk:"
  df -h / | grep -v Filesystem
  echo ""
  echo "Memory:"
  free -h | grep Mem
  echo ""
  exit 0
fi

echo "=== Provisioning Ubuntu for Supabase ==="
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  echo "This script needs sudo for apt install. Run with sudo or ensure user has sudo."
fi

# Update
echo "[*] apt update..."
sudo apt-get update -y

echo "[*] Installing base packages..."
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  python3 \
  python3-venv \
  python3-pip \
  openssl \
  git \
  ufw \
  htop \
  jq \
  unzip \
  make \
  build-essential

# Docker install if missing
if ! command -v docker >/dev/null 2>&1; then
  echo "[*] Installing Docker CE..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
  if [ -f /etc/apt/keyrings/docker.gpg ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || {
      echo "[WARN] Docker CE install failed, trying docker.io"
      sudo apt-get install -y docker.io docker-compose-plugin
    }
  else
    sudo apt-get install -y docker.io docker-compose-plugin
  fi

  sudo systemctl enable --now docker
  sudo usermod -aG docker $USER || true
  echo "[OK] Docker installed"
else
  echo "[OK] Docker already installed: $(docker --version)"
  # Ensure compose plugin
  if ! docker compose version >/dev/null 2>&1; then
    echo "[*] Installing compose plugin..."
    sudo apt-get install -y docker-compose-plugin || true
  fi
fi

# Enable docker to start on boot
sudo systemctl enable docker

# Python venv
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$ROOT_DIR/.venv" ]; then
  echo "[*] Creating Python venv..."
  python3 -m venv "$ROOT_DIR/.venv"
fi
# shellcheck disable=SC1091
source "$ROOT_DIR/.venv/bin/activate"
pip install --upgrade pip -q
pip install -q -r "$ROOT_DIR/requirements.txt"
echo "[OK] Python venv ready at $ROOT_DIR/.venv"

# UFW setup (safe defaults)
echo "[*] Configuring UFW (safe defaults)..."
sudo ufw allow 22/tcp || true
sudo ufw allow 80/tcp || true
sudo ufw allow 443/tcp || true
# Don't auto-enable if not already enabled to avoid locking out
if sudo ufw status | grep -q "Status: active"; then
  echo "[OK] UFW already active"
  sudo ufw status
else
  echo "[WARN] UFW not active - not auto-enabling to avoid SSH lockout"
  echo "       To enable: sudo ufw enable"
  echo "       Then open your Supabase ports: sudo ufw allow 8000:10000/tcp"
fi

# System tuning for Postgres
echo "[*] Checking system tuning..."
echo "vm.max_map_count = 262144" | sudo tee -a /etc/sysctl.conf >/dev/null 2>&1 || true
sudo sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true

# Disk space check
echo ""
echo "=== System Summary ==="
echo -n "Docker: "; docker --version
echo -n "Compose: "; docker compose version
echo -n "Python: "; python3 --version
echo "Disk Free:"
df -h / | tail -n1
echo "Memory:"
free -h | grep Mem
echo ""
echo -e "${GREEN}Provisioning complete!${NC}"
echo "Next: ./deploy.sh my-supabase 8000 --non-interactive --yes"
echo "If you installed docker now, you may need to re-login: newgrp docker or logout/login"
