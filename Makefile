# Supabase Easy Makefile for Ubuntu Server
# Usage:
#   make help
#   make install-deps           # install docker + python deps on Ubuntu
#   make create PROJECT=myapp PORT=8000
#   make start PROJECT=myapp
#   make stop PROJECT=myapp
#   make status PROJECT=myapp
#   make logs PROJECT=myapp
#   make backup PROJECT=myapp
#   make deploy PROJECT=myapp PORT=8000 DOMAIN=api.example.com

PROJECT ?= my-supabase
PORT ?= 8000
DOMAIN ?= localhost
PROTOCOL ?= http
USER_NAME ?= supabase
PASS ?= 
ROOT_DIR := $(shell pwd)
PROJECT_PATH := $(ROOT_DIR)/projects/$(PROJECT)

.PHONY: help install-deps create start stop restart status logs backup weekly-backup setup-weekly-backup deploy clean list quickstart

help:
	@echo "Supabase Easy Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  make install-deps                Install Docker & deps on Ubuntu"
	@echo "  make create PROJECT=name PORT=8000        Create new project"
	@echo "  make create PROJECT=name PORT=8000 DOMAIN=example.com PROTOCOL=https"
	@echo "  make start PROJECT=name          Start project"
	@echo "  make stop PROJECT=name           Stop project (keep data)"
	@echo "  make restart PROJECT=name        Restart project"
	@echo "  make status PROJECT=name         Show status"
	@echo "  make logs PROJECT=name           Follow logs"
	@echo "  make backup PROJECT=name         Backup DB + storage (one-off)"
	@echo "  make weekly-backup PROJECT=name  Weekly backup with verify + retention"
	@echo "  make setup-weekly-backup PROJECT=sony  Setup weekly cron Sunday 3am"
	@echo "  make deploy PROJECT=name PORT=8000        One-command deploy (create+start)"
	@echo "  make quickstart                  Quick localhost deploy: my-supabase 8000"
	@echo "  make list                        List all projects"
	@echo "  make clean PROJECT=name          WIPE data (danger!)"
	@echo ""
	@echo "Backup Examples:"
	@echo "  make weekly-backup PROJECT=sony"
	@echo "  make setup-weekly-backup PROJECT=sony"
	@echo "  ./scripts/setup_weekly_backup.sh sony --day 0 --hour 3 --s3 s3://bucket/sony"
	@echo ""
	@echo "Examples:"
	@echo "  make deploy PROJECT=myapp PORT=8000"
	@echo "  make deploy PROJECT=myapp PORT=8000 DOMAIN=api.mydomain.com PROTOCOL=https USER_NAME=admin PASS=Strong123!"
	@echo ""

install-deps:
	@echo "[*] Installing Ubuntu dependencies..."
	@chmod +x deploy.sh scripts/*.sh 2>/dev/null || true
	@if [ -f /etc/os-release ]; then cat /etc/os-release | grep PRETTY; fi
	sudo apt-get update -y
	sudo apt-get install -y ca-certificates curl gnupg lsb-release python3-venv python3-pip openssl git ufw
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "[*] Installing Docker..."; \
		sudo mkdir -p /etc/apt/keyrings; \
		curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true; \
		echo "deb [arch=$$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list; \
		sudo apt-get update -y; \
		sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || sudo apt-get install -y docker.io docker-compose-plugin; \
		sudo systemctl enable --now docker; \
		sudo usermod -aG docker $$USER || true; \
	else \
		echo "[OK] Docker already installed: $$(docker --version)"; \
	fi
	@python3 -m venv .venv || true
	@.venv/bin/pip install -q -r requirements.txt
	@echo "[OK] Deps ready. You may need to re-login for docker group."

create:
	@echo "[*] Creating project $(PROJECT) on port $(PORT) domain $(DOMAIN)"
	@if [ "$(DOMAIN)" = "localhost" ]; then \
		printf "Y\n" | python3 supabase_manager.py create $(PROJECT) --base-port $(PORT); \
	else \
		printf "N\n$(PROTOCOL)\n$(DOMAIN)\n" | python3 supabase_manager.py create $(PROJECT) --base-port $(PORT); \
	fi
	@.venv/bin/python generate_keys.py --env-file $(PROJECT_PATH)/.env || python3 generate_keys.py --env-file $(PROJECT_PATH)/.env
	@if [ -n "$(PASS)" ]; then \
		.venv/bin/python update_env_credentials.py --project-name $(PROJECT) --username $(USER_NAME) --password '$(PASS)' || python3 update_env_credentials.py --project-name $(PROJECT) --username $(USER_NAME) --password '$(PASS)'; \
	else \
		GEN_PASS=$$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12); \
		echo "Generated password: $$GEN_PASS"; \
		.venv/bin/python update_env_credentials.py --project-name $(PROJECT) --username $(USER_NAME) --password "$$GEN_PASS" || python3 update_env_credentials.py --project-name $(PROJECT) --username $(USER_NAME) --password "$$GEN_PASS"; \
		echo "$$GEN_PASS" > $(PROJECT_PATH)/.dashboard_pass; \
	fi

start:
	cd $(PROJECT_PATH) && docker compose up -d && docker compose ps

stop:
	cd $(PROJECT_PATH) && docker compose down
	@echo "Stopped $(PROJECT) - data preserved in volumes/db/data"

restart:
	cd $(PROJECT_PATH) && docker compose down && docker compose up -d && docker compose ps

status:
	python3 supabase_manager.py status $(PROJECT) || (cd $(PROJECT_PATH) && docker compose ps)

logs:
	cd $(PROJECT_PATH) && docker compose logs -f --tail=200

logs-all:
	cd $(PROJECT_PATH) && docker compose logs -f

backup:
	@mkdir -p $(PROJECT_PATH)/backups
	@echo "[*] Backing up $(PROJECT)..."
	@docker exec -t $(PROJECT)-db pg_dumpall -U postgres > $(PROJECT_PATH)/backups/$(PROJECT)_$$(date +%F_%H%M)_pg_dumpall.sql && echo "[OK] DB backup done" || echo "[FAIL] DB backup failed"
	@tar -czf $(PROJECT_PATH)/backups/$(PROJECT)_$$(date +%F_%H%M)_storage.tar.gz -C $(PROJECT_PATH) volumes/storage 2>/dev/null && echo "[OK] Storage backup done" || echo "[WARN] No storage"
	@ls -lh $(PROJECT_PATH)/backups | tail -n 20

weekly-backup:
	@echo "[*] Weekly backup for $(PROJECT)..."
	@./scripts/weekly_backup.sh $(PROJECT) --verify
	@ls -lh $(PROJECT_PATH)/backups/weekly | tail -n 20

setup-weekly-backup:
	@echo "[*] Setting up weekly backup cron for $(PROJECT) (Sunday 3am, keep 28 days)"
	@./scripts/setup_weekly_backup.sh $(PROJECT) --day 0 --hour 3 --keep-days 28

setup-weekly-backup-systemd:
	@echo "[*] Setting up weekly backup systemd timer for $(PROJECT)"
	@./scripts/setup_weekly_backup.sh $(PROJECT) --systemd --day 0 --hour 3 --keep-days 28

deploy:
	@echo "[*] One-command deploy: $(PROJECT) port $(PORT) domain $(DOMAIN)"
	@./deploy.sh $(PROJECT) $(PORT) --domain $(DOMAIN) --protocol $(PROTOCOL) --user $(USER_NAME) $(if $(PASS),--pass $(PASS),) --non-interactive --yes --skip-deps || \
	./deploy.sh $(PROJECT) $(PORT) --non-interactive --yes

quickstart:
	./deploy.sh my-supabase 8000 --non-interactive --yes

list:
	python3 supabase_manager.py list || ls -1 projects/

clean:
	@echo "[DANGER] This will DELETE all data for $(PROJECT)!"
	@echo "Path: $(PROJECT_PATH)/volumes/db/data"
	@read -p "Type YES to confirm wipe: " confirm; \
	if [ "$$confirm" = "YES" ]; then \
		cd $(PROJECT_PATH) && docker compose down -v --remove-orphans || true; \
		rm -rf $(PROJECT_PATH)/volumes/db/data && mkdir -p $(PROJECT_PATH)/volumes/db/data; \
		echo "[OK] Wiped $(PROJECT)"; \
	else \
		echo "Aborted"; \
	fi

psql:
	docker exec -it $(PROJECT)-db psql -U postgres

shell:
	docker exec -it $(PROJECT)-db bash
