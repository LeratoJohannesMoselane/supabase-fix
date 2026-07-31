# Ubuntu Easy Workflow — Create Supabase DB in 1 Command

This guide gives you the **absolute easiest** path from a fresh Ubuntu 20.04/22.04/24.04 server to a running self-hosted Supabase DB.

You have 3 options — from simplest to most automated.

---

## Option 1: 1-Command Deploy (Recommended)

On your Ubuntu server:

```bash
git clone https://github.com/LeratoJohannesMoselane/supabase-fix.git
cd supabase-fix
chmod +x deploy.sh
./deploy.sh my-supabase 8000 --non-interactive --yes
```

That’s it. What it does:

1. Checks Docker, installs if missing (docker-ce + compose plugin)
2. Creates Python venv + installs `requirements.txt`
3. Creates `projects/my-supabase` via `supabase_manager.py` (non-interactive, localhost CORS *)
4. Generates secure `JWT_SECRET`, `ANON_KEY`, `SERVICE_ROLE_KEY`
5. Sets dashboard password (random if not given)
6. Runs `docker compose up -d`
7. Saves credentials to `projects/my-supabase/.credentials`
8. Prints Studio/API/DB URLs

**Access:**

```bash
cat projects/my-supabase/.credentials

# Studio:
http://YOUR_SERVER_IP:10000   # if base port 8000 -> studio 10000
# API:
http://YOUR_SERVER_IP:8000

# From localhost on server:
http://localhost:10000
http://localhost:8000
```

**Custom domain (production):**

```bash
./deploy.sh myapp 8000 --domain api.example.com --protocol https --user admin --pass 'Str0ng!Pass123' --open-firewall
```

This auto-sets:

- `SUPABASE_PUBLIC_URL=https://api.example.com:8000`
- `SITE_URL=https://api.example.com:10000`
- CORS to only allow `https://api.example.com`

---

## Option 2: Makefile Workflow (if you prefer make)

```bash
sudo apt install make -y
git clone https://github.com/LeratoJohannesMoselane/supabase-fix.git
cd supabase-fix

make install-deps
make deploy PROJECT=myapp PORT=8000          # localhost
# or
make deploy PROJECT=myapp PORT=8000 DOMAIN=api.example.com PROTOCOL=https USER_NAME=admin PASS=Secret123
make status PROJECT=myapp
make logs PROJECT=myapp
make backup PROJECT=myapp
```

All Makefile targets:

- `make quickstart` → creates `my-supabase` on 8000
- `make create PROJECT=x PORT=8000`
- `make start PROJECT=x`
- `make stop PROJECT=x` (keeps data!)
- `make restart PROJECT=x`
- `make backup PROJECT=x` → `projects/x/backups/`
- `make psql PROJECT=x` → drops into psql
- `make clean PROJECT=x` → **WIPES DATA** (asks for YES)

---

## Option 3: Native scripts (step-by-step manual control)

If you want to understand each step:

```bash
# 1. Provision Ubuntu (docker, python, ufw, tuning)
chmod +x scripts/ubuntu-provision.sh
./scripts/ubuntu-provision.sh          # needs sudo
# or just check
./scripts/ubuntu-provision.sh --check-only

# 2. Create project (non-interactive)
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

printf "Y\n" | python3 supabase_manager.py create demo --base-port 8000
python3 generate_keys.py --env-file projects/demo/.env
python3 update_env_credentials.py --project-name demo --username supabase --password 'MyPass123'

# 3. Start
cd projects/demo
docker compose up -d
docker compose ps
docker compose logs -f

# 4. Backup
cd ../..
./scripts/backup.sh demo
```

Daily backup cron:

```bash
(crontab -l 2>/dev/null; echo "0 2 * * * /home/ubuntu/supabase-fix/scripts/backup.sh my-supabase --cron >> /home/ubuntu/supabase-fix/projects/my-supabase/backups/cron.log 2>&1") | crontab -
```

---

## GitHub Actions Workflow

We include `.github/workflows/supabase-ubuntu.yml` which offers 3 deploy targets:

- `ci-test`: runs on `ubuntu-latest` runner, creates project, boots stack, healthchecks (great for testing PRs)
- `self-hosted-runner`: runs on your own Ubuntu server registered as self-hosted runner, calls `deploy.sh`
- `ssh-deploy`: from GitHub cloud, SSH into your server and run `deploy.sh`

**Manual run:**

GitHub → Actions → Supabase Ubuntu Deploy → Run workflow → choose project name, port, domain, target.

For SSH mode, set repo secrets:

- `SSH_HOST`: your.server.ip
- `SSH_USER`: ubuntu
- `SSH_KEY`: private key content

---

## Firewall (UFW)

By default we **do NOT** auto-open Postgres (5432) to public. If you want:

```bash
# Open API + Studio only (recommended)
sudo ufw allow 8000/tcp
sudo ufw allow 10000/tcp
sudo ufw allow 22/tcp
sudo ufw enable

# Or let deploy script do it:
./deploy.sh my-supabase 8000 --open-firewall

# Only open DB if you REALLY need direct external psql (use SSH tunnel instead!)
# sudo ufw allow 5432/tcp
```

Or restrict DB to your IP:

```bash
sudo ufw allow from YOUR_HOME_IP to any port 5432
```

---

## What Ports Get Used?

Base port 8000 generates:

- `KONG_HTTP` = 8000 → API gateway (REST, Auth, Storage, Functions)
- `KONG_HTTPS` = 8443
- `POSTGRES` = 9000 (base+1000 logic, but our manager picks free port if busy)
- `POOLER` = 9001 (transaction pooler 6543 mapped)
- `STUDIO` = 10000 (base+2000)
- `ANALYTICS` = 11000

Check actual ports in `projects/<name>/.env` → grep `_PORT=`.

If port busy, deploy.sh auto-finds next free one. So use `make status` or `cat .credentials`.

---

## Daily Operations Cheatsheet

```bash
cd projects/my-supabase

# status
docker compose ps

# logs
docker compose logs -f --tail=100
docker compose logs -f studio kong db

# stop safely (keeps data)
docker compose down

# stop + keep named volumes explicitly
../deploy.sh my-supabase 8000 --skip-deps  # restart helper, or
docker compose down   # NOT -v!

# update images + restart without wiping
docker compose pull
docker compose up -d --remove-orphans

# psql
docker exec -it my-supabase-db psql -U postgres

# backup
../../scripts/backup.sh my-supabase

# restore (from dump .gz)
gunzip -c backups/my-supabase_2025-01-01_020000_pg_dumpall.sql.gz | docker exec -i my-supabase-db psql -U postgres

# rotate keys (will invalidate old sessions)
cd ../..
python3 generate_keys.py --env-file projects/my-supabase/.env --kong-file projects/my-supabase/volumes/api/kong.yml
cd projects/my-supabase && docker compose up -d --force-recreate kong auth rest

# change dashboard password
cd ../..
python3 update_env_credentials.py --project-name my-supabase --username admin --password 'NewStrongPass!'
cd projects/my-supabase && docker compose up -d --force-recreate kong studio
```

---

## Security Checklist (after deploy)

- [ ] `cat projects/<name>/.credentials` saved securely, not in git
- [ ] `chmod 600 projects/<name>/.env` (deploy.sh already does)
- [ ] Change default `my-supabase` to real project name
- [ ] Enable UFW, only open needed ports
- [ ] If public domain, put Nginx/Caddy/Traefik in front with TLS
- [ ] Apply RLS policies: `sample_security_policies.sql`
- [ ] Disable email autoconfirm for prod: set `ENABLE_EMAIL_AUTOCONFIRM=false` in `.env` + SMTP
- [ ] Setup S3 backup or at least cron backup
- [ ] Never expose `SERVICE_ROLE_KEY` in frontend

Sample Nginx reverse proxy snippet for `api.example.com` → `localhost:8000`:

```nginx
server {
  listen 443 ssl;
  server_name api.example.com;
  ssl_certificate /etc/letsencrypt/...
  ssl_certificate_key /etc/letsencrypt/...

  location / {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
```

---

## Troubleshooting

- **Port already in use**: `sudo lsof -i :8000` or use different base `--base-port 9000`
- **Docker permission denied**: `newgrp docker` or logout/login after install
- **DB unhealthy**: `docker compose logs db --tail=100`
- **Studio 404 `/api/platform/notifications`**: harmless, self-hosted Studio calls cloud-only endpoint
- **Auth redirects fail**: check `SITE_URL`, `ADDITIONAL_REDIRECT_URLS`, `SUPABASE_PUBLIC_URL` in `.env`, then `docker compose up -d --force-recreate auth studio`
- **Storage upload fails**: check `STORAGE_BACKEND=file` and `volumes/storage` exists + writable

Full docs: `docs/TROUBLESHOOTING.md`, `docs/PORT_REFERENCE.md`

---

## TL;DR for your Ubuntu server

```bash
git clone https://github.com/LeratoJohannesMoselane/supabase-fix.git
cd supabase-fix
./deploy.sh myapp 8000 --yes --non-interactive
cat projects/myapp/.credentials
```

Done — Supabase DB live in <2 min.
