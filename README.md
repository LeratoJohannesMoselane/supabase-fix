# supabase-fix — Easy Supabase DB on Ubuntu Server

Self-hosted Supabase deployment tooling and Docker Compose configuration. **New: 1-command Ubuntu deploy** — see `docs/UBUNTU_EASY_WORKFLOW.md`.

> 🚀 **Quick Ubuntu Install (TL;DR)**
> ```bash
> git clone https://github.com/LeratoJohannesMoselane/supabase-fix.git
> cd supabase-fix
> ./deploy.sh my-supabase 8000 --non-interactive --yes
> cat projects/my-supabase/.credentials
> ```
> Studio → `http://YOUR_IP:10000`  |  API → `http://YOUR_IP:8000`  |  Docs: `docs/UBUNTU_EASY_WORKFLOW.md`

This repo can generate/manage separate Supabase projects under `projects/<project-name>` with their own ports, `.env`, volumes, and Docker Compose files. It can also run a Supabase stack directly from the repository root when the required root `volumes/` config files are present.

## Table of contents

- [What is included](#what-is-included)
- [Important data-safety notes](#important-data-safety-notes)
- [Prerequisites](#prerequisites)
- [Quick start: create and run a secure project](#quick-start-create-and-run-a-secure-project)
- [Project manager commands](#project-manager-commands)
- [Run the root Docker Compose stack manually](#run-the-root-docker-compose-stack-manually)
- [Update an already-running project](#update-an-already-running-project)
- [Regenerate / rotate Supabase keys](#regenerate--rotate-supabase-keys)
- [Update dashboard username/password](#update-dashboard-usernamepassword)
- [Persistent storage, backups, and restore](#persistent-storage-backups-and-restore)
- [AWS production deployment](#aws-production-deployment)
- [Environment variables you will commonly edit](#environment-variables-you-will-commonly-edit)
- [Service URLs and ports](#service-urls-and-ports)
- [Common operational commands](#common-operational-commands)
- [Known Supabase Studio browser 404s](#known-supabase-studio-browser-404s)
- [Troubleshooting](#troubleshooting)
- [Repository files](#repository-files)

## What is included

Main files:

| File / folder | Purpose |
| --- | --- |
| `docker-compose.yml` | Base self-hosted Supabase Docker Compose stack (Postgres 17 + Envoy API gateway). |
| `docker-compose.kong.yml` | Optional override that swaps the default Envoy gateway for Kong. |
| `docker-compose.logs.yml` | Optional override that adds Logflare (analytics) + Vector (log pipeline). |
| `docker-compose.pg15.yml` | Optional override that pins the database to Postgres 15. |
| `docker-compose.aws.yml` | AWS override for S3-backed storage and AWS-friendly settings. |
| `.env.aws.example` | Example environment file for AWS/RDS/S3 deployments. Copy to `.env` and edit. |
| `supabase_manager.py` | CLI for creating, starting, stopping, listing, and resetting generated projects. |
| `supabase_setup.py` | Project generator used by `supabase_manager.py`. |
| `setup_secure_supabase.sh` | Guided secure project creation script. |
| `generate_keys.py` | Generates/rotates `JWT_SECRET`, `ANON_KEY`, and `SERVICE_ROLE_KEY`. |
| `update_env_credentials.py` | Updates Studio dashboard basic-auth credentials in `.env` and `kong.yml`. |
| `update_security.py` | Applies security updates to an existing generated project. |
| `volumes/` | Root-stack bind-mounted config/data folders. Generated projects get their own `volumes/`. |
| `docs/` | AWS deployment, ports, Realtime config, and troubleshooting guides. |

The stack includes Supabase Studio, the API gateway (Envoy by default, Kong via override), Auth, PostgREST, Realtime, Storage, ImgProxy, Postgres Meta, Edge Functions, Logflare/Analytics, Vector, Postgres, and Supavisor.

### Image versions (latest published tags, checked 2026-09-08)

| Service | Image | Version |
| --- | --- | --- |
| Studio | `supabase/studio` | `2026.09.07-sha-7996410` |
| API gateway (default) | `envoyproxy/envoy` | `v1.39.1` |
| API gateway (override) | `kong/kong` | `3.9.3` |
| Auth (GoTrue) | `supabase/gotrue` | `v2.196.0` |
| REST (PostgREST) | `postgrest/postgrest` | `v16.2` |
| Realtime | `supabase/realtime` | `v2.134.12` |
| Storage | `supabase/storage-api` | `v1.74.1` |
| ImgProxy | `darthsim/imgproxy` | `v4.0.14` |
| Meta | `supabase/postgres-meta` | `v0.99.0` |
| Edge Functions | `supabase/edge-runtime` | `v1.76.2` |
| Database (default) | `supabase/postgres` | `17.6.1.169` |
| Database (PG15 override) | `supabase/postgres` | `15.14.1.169` |
| Supavisor (pooler) | `supabase/supavisor` | `2.9.12` |
| Analytics (Logflare) | `supabase/logflare` | `1.50.11` |
| Vector | `timberio/vector` | `0.58.0-alpine` |

> `supabase/supavisor` is pinned to `2.9.12` because that is the newest tag
> published to Docker Hub, even though the GitHub project has tagged `v2.9.12`.

#### Environment variables that changed with these versions

| Service | Change |
| --- | --- |
| PostgREST v16 | `PGRST_DB_USE_LEGACY_GUCS` removed (gone since v11.2). New `PGRST_URL_USE_LEGACY_TARGET_NAMES` (default `true`) controls the deprecated "filter an aliased embedded resource by its relation name" behaviour. |
| Storage v1.72 | Option names modernised: `FILE_SIZE_LIMIT` -> `UPLOAD_FILE_SIZE_LIMIT`, `FILE_STORAGE_BACKEND_PATH` -> `STORAGE_FILE_BACKEND_PATH`, `GLOBAL_S3_*` -> `STORAGE_S3_*`, `REGION` -> `SERVER_REGION`, `ENABLE_IMAGE_TRANSFORMATION` -> `IMAGE_TRANSFORMATION_ENABLED` (the old names still work as fallbacks). |
| ImgProxy v4 | `IMGPROXY_ENABLE_WEBP_DETECTION` removed -> use `IMGPROXY_AUTO_WEBP`; `IMGPROXY_CONCURRENCY` -> `IMGPROXY_WORKERS`; `IMGPROXY_READ_TIMEOUT`/`IMGPROXY_WRITE_TIMEOUT` -> `IMGPROXY_READ_REQUEST_TIMEOUT`/`IMGPROXY_TIMEOUT`; OpenTelemetry now uses the standard `OTEL_*` variables. `IMGPROXY_USE_ETAG`/`IMGPROXY_USE_LAST_MODIFIED` default to `true`. |
| Vector 0.58 | `${VAR}` interpolation inside config files is disabled by default since 0.57, so the `vector` service now sets `VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true` (`volumes/logs/vector.yml` interpolates the Logflare key). |

### API gateway

The default API gateway in this stack is **Envoy** (`api-gw` service), which
matches the latest official supabase `master` branch. To keep using Kong
instead, append the override file:

```bash
docker compose -f docker-compose.yml -f docker-compose.kong.yml up -d
```

The Kong override keeps the legacy `kong`/`envoy` network aliases working so
internal configs that reference either hostname resolve to the active gateway.

### Postgres 17 (default) vs Postgres 15

Postgres 17 (`supabase/postgres:17.6.1.169`) is the new default. If you are
upgrading an existing Postgres 15 deployment, use `docker-compose.pg15.yml`
first and then follow the in-place upgrade at
<https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17>. To stay
on Postgres 15:

```bash
docker compose -f docker-compose.yml -f docker-compose.pg15.yml up -d
```

### Analytics (Logflare) and Vector

Logflare (`analytics`) and Vector are now shipped as an opt-in override to
match the upstream `master` branch layout. To enable logging:

```bash
docker compose -f docker-compose.yml -f docker-compose.logs.yml up -d
```

The latest Logflare image expects `LOGFLARE_PUBLIC_ACCESS_TOKEN` and
`LOGFLARE_PRIVATE_ACCESS_TOKEN` in `.env` (the older single `LOGFLARE_API_KEY`
is still accepted for backwards compatibility).

## Important data-safety notes

Read this before stopping, updating, resetting, or rotating keys.

- Database data is persisted in `volumes/db/data` for the root stack, or `projects/<project>/volumes/db/data` for generated projects.
- Supabase Storage files are persisted in `volumes/storage`, or `projects/<project>/volumes/storage`, unless using the AWS S3 override.
- Do **not** delete `volumes/db/data` unless you intentionally want to wipe the database.
- Do **not** run reset commands on a production project unless you have verified backups.
- Prefer `docker compose down` without `-v` for normal stops.
- If using `supabase_manager.py stop`, use `--keep-volumes` for existing projects:

```bash
./supabase_manager.py stop <project-name> --keep-volumes
```

Without `--keep-volumes`, the manager calls `docker compose down -v`, which removes Docker named volumes such as `db-config`. Bind-mounted database files may remain, but removing named volumes can still break important Supabase/Postgres key material.

## Prerequisites

Install these on the machine running Supabase:

- Docker Engine
- Docker Compose plugin (`docker compose`, not old `docker-compose`)
- Python 3.10+
- `pip`
- `openssl` for the secure setup script

Install Python dependencies:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Make scripts executable if needed:

```bash
chmod +x setup_secure_supabase.sh supabase_manager.py supabase_setup.py generate_keys.py update_security.py update_env_credentials.py
```

## Quick start: create and run a secure project

Recommended for a new local/self-hosted project:

```bash
./setup_secure_supabase.sh advanta 8000
```

What this does:

1. Creates `projects/advanta`.
2. Generates a project-specific `.env`.
3. Generates new Supabase JWT/API keys.
4. Updates Kong with the generated keys.
5. Sets Studio dashboard credentials.
6. Copies security docs and sample RLS policies.
7. Starts the project with Docker Compose.

If you omit the base port, the script chooses available ports automatically:

```bash
./setup_secure_supabase.sh advanta
```

After startup, access URLs are printed in the terminal. They are usually similar to:

```text
Studio Dashboard: http://localhost:<STUDIO_PORT>
API Endpoint:     http://localhost:<KONG_HTTP_PORT>
PostgreSQL:       localhost:<POSTGRES_PORT>
```

For a generated project, you can also inspect the generated project README:

```bash
cat projects/advanta/README.md
```

## Project manager commands

The project manager stores projects under `projects/<project-name>`.

### Create a project

```bash
./supabase_manager.py create advanta --base-port 8000
```

The generator asks whether the project is for localhost. For localhost, it uses `http://localhost` and permissive local CORS. For a deployed domain, answer `N` and provide protocol/domain.

### Start a project

```bash
./supabase_manager.py start advanta --verbose
```

### Check status

```bash
./supabase_manager.py status advanta
```

Or directly:

```bash
cd projects/advanta
docker compose ps
```

### List projects

```bash
./supabase_manager.py list
```

### Stop a project safely

Use this for normal stops:

```bash
./supabase_manager.py stop advanta --keep-volumes
```

Or directly:

```bash
cd projects/advanta
docker compose down
```

### Reset a project

This deletes database data. Use only when you intentionally want a clean database:

```bash
./supabase_manager.py reset advanta
```

Or inside the project:

```bash
cd projects/advanta
./reset.sh
```

Do not use reset on production unless you have backups and intend to wipe data.

## Run the root Docker Compose stack manually

The recommended way to start fresh is still `setup_secure_supabase.sh`, because it generates all required volume/config files for you.

The root `docker-compose.yml` is useful when this repository root itself is the deployment folder. Before running it, confirm these required files exist:

```bash
ls volumes/api/envoy/envoy.yaml \
   volumes/api/envoy/cds.yaml \
   volumes/api/envoy/lds.template.yaml \
   volumes/api/envoy/docker-entrypoint.sh \
   volumes/api/kong.yml \
   volumes/api/kong-entrypoint.sh \
   volumes/logs/vector.yml \
   volumes/pooler/pooler.exs \
   volumes/db/_supabase.sql \
   volumes/db/logs.sql \
   volumes/db/jwt.sql \
   volumes/db/pooler.sql \
   volumes/db/realtime.sql \
   volumes/db/roles.sql \
   volumes/db/webhooks.sql \
   volumes/functions/main/index.ts
```

If those files are missing, create a generated project instead:

```bash
./setup_secure_supabase.sh advanta 8000
```

Or copy the generated config files from an existing known-good project into the root `volumes/` tree before using the root Compose stack.

Note: the current root `docker-compose.yml` publishes Kong, Analytics, PostgreSQL, and Pooler ports. It does not publish Studio directly unless you add a `ports:` mapping to the `studio` service or route/proxy to `studio:3000` from your reverse proxy.

### 1. Create `.env`

This repo includes `.env.aws.example`. For AWS, copy it directly:

```bash
cp .env.aws.example .env
```

Then edit `.env` and replace all placeholder values.

For local Docker-only Postgres, make sure at minimum:

```env
POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_DB_PORT=5432
POSTGRES_PORT=5432
KONG_HTTP_PORT=8000
KONG_HTTPS_PORT=8443
STUDIO_PORT=3000
SUPABASE_PUBLIC_URL=http://localhost:8000
API_EXTERNAL_URL=http://localhost:8000
SITE_URL=http://localhost:3000
DOCKER_SOCKET_LOCATION=/var/run/docker.sock
```

Also change all secrets before using it for anything real:

```env
POSTGRES_PASSWORD=...
JWT_SECRET=...
ANON_KEY=...
SERVICE_ROLE_KEY=...
DASHBOARD_USERNAME=...
DASHBOARD_PASSWORD=...
SECRET_KEY_BASE=...
VAULT_ENC_KEY=...
LOGFLARE_API_KEY=...
LOGFLARE_LOGGER_BACKEND_API_KEY=...
```

You can generate the JWT/API keys with `generate_keys.py`; see [Regenerate / rotate Supabase keys](#regenerate--rotate-supabase-keys).

### 2. Start the root stack

```bash
docker compose up -d
```

### 3. View status/logs

```bash
docker compose ps
docker compose logs -f studio
docker compose logs -f kong
docker compose logs -f db
```

### 4. Stop without deleting data

```bash
docker compose down
```

### 5. Destroy/reset the root stack

This removes containers and named volumes. If you also remove `volumes/db/data`, the database is wiped.

```bash
docker compose down -v --remove-orphans
rm -rf volumes/db/data
mkdir -p volumes/db/data
```

## Update an already-running project

There are two different update types:

1. **Restart/apply config changes** after editing `.env`, `kong.yml`, Compose, etc.
2. **Upgrade container images/repo files** to newer versions.

Always back up first.

### Safe update checklist

For a generated project:

```bash
PROJECT=advanta
cd projects/$PROJECT

# 1. Check current containers
docker compose ps

# 2. Back up database and storage before making changes
mkdir -p backups
docker exec -t ${PROJECT}-db pg_dumpall -U postgres > backups/${PROJECT}_$(date +%F_%H%M)_pg_dumpall.sql
tar -czf backups/${PROJECT}_$(date +%F_%H%M)_storage.tar.gz volumes/storage || true

# 3. Pull updated images if image tags changed or you want latest available for existing tags
docker compose pull

# 4. Recreate changed containers without deleting data
docker compose up -d --remove-orphans

# 5. Check health/logs
docker compose ps
docker compose logs --tail=100 studio kong auth rest realtime storage db
```

For the root stack:

```bash
mkdir -p backups
docker exec -t supabase-db pg_dumpall -U postgres > backups/root_$(date +%F_%H%M)_pg_dumpall.sql
tar -czf backups/root_$(date +%F_%H%M)_storage.tar.gz volumes/storage || true

docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```

### Apply only `.env` changes

If you changed environment variables, recreate containers:

```bash
docker compose up -d --force-recreate
```

For some changes, a normal recreate is enough:

```bash
docker compose up -d
```

### Apply `kong.yml` changes

Kong reads `volumes/api/kong.yml` on startup. Restart/recreate Kong:

```bash
docker compose up -d --force-recreate kong
```

If in doubt:

```bash
docker compose restart kong
```

### Update generated projects with changed templates from this repo

Generated projects are copied into `projects/<project>`. Changes to this repository's root `docker-compose.yml` or templates do not automatically rewrite existing generated projects.

For an existing generated project, update carefully:

1. Back up the project folder and database.
2. Compare the root/template changes with the project's files:

```bash
diff -u docker-compose.yml projects/advanta/docker-compose.yml || true
```

3. Manually merge needed changes into `projects/advanta/docker-compose.yml`, `.env`, and `volumes/api/kong.yml`.
4. Recreate containers:

```bash
cd projects/advanta
docker compose up -d --remove-orphans
```

## Regenerate / rotate Supabase keys

Supabase uses three related values:

- `JWT_SECRET`: secret used to sign/verify JWTs.
- `ANON_KEY`: public anon API key signed with `JWT_SECRET`.
- `SERVICE_ROLE_KEY`: admin/service key signed with `JWT_SECRET`.

Important effects of rotating these keys:

- Existing user sessions/JWTs become invalid and users may need to sign in again.
- All frontend apps must be updated with the new `ANON_KEY`.
- All backend jobs/server integrations must be updated with the new `SERVICE_ROLE_KEY`.
- Never expose `SERVICE_ROLE_KEY` in browser/client code.

### Generate keys without modifying files

```bash
python3 generate_keys.py
```

Copy the printed values manually into your `.env` and Kong config if needed.

### Rotate keys for a generated project

```bash
PROJECT=advanta
python3 generate_keys.py \
  --env-file projects/$PROJECT/.env \
  --kong-file projects/$PROJECT/volumes/api/kong.yml
```

Then restart the project:

```bash
cd projects/$PROJECT
docker compose down
docker compose up -d
```

Update your applications with the new keys.

### Rotate keys for the root stack

```bash
python3 generate_keys.py \
  --env-file .env \
  --kong-file volumes/api/kong.yml

docker compose down
docker compose up -d
```

### Use a longer JWT secret or expiry

```bash
python3 generate_keys.py \
  --env-file projects/advanta/.env \
  --kong-file projects/advanta/volumes/api/kong.yml \
  --jwt-length 64 \
  --expiry-years 10
```

### Verify JWT/API key consistency

After rotating, `JWT_SECRET`, `ANON_KEY`, and `SERVICE_ROLE_KEY` must all match each other. The `ANON_KEY` and `SERVICE_ROLE_KEY` in `volumes/api/kong.yml` must also match `.env`.

Quick checks:

```bash
grep -E '^(JWT_SECRET|ANON_KEY|SERVICE_ROLE_KEY)=' projects/advanta/.env
grep -A4 -E 'username: (anon|anonymous|service_role)' projects/advanta/volumes/api/kong.yml
```

## Update dashboard username/password

For a generated project:

```bash
python3 update_env_credentials.py \
  --project-name advanta \
  --username supabase \
  --password 'use-a-strong-password'

cd projects/advanta
docker compose up -d --force-recreate kong studio
```

This updates:

- `projects/advanta/.env`
- `projects/advanta/volumes/api/kong.yml`

For the root stack, edit `.env` and `volumes/api/kong.yml` manually, then recreate Kong/Studio:

```bash
docker compose up -d --force-recreate kong studio
```

## Persistent storage, backups, and restore

### What is persistent?

Root stack:

```text
volumes/db/data      -> Postgres database files
volumes/storage      -> Supabase Storage uploaded files when using file backend
Docker volume db-config -> Postgres custom config / key material
```

Generated project:

```text
projects/<project>/volumes/db/data
projects/<project>/volumes/storage
Docker volume <project>_db-config
```

AWS S3 override:

```text
Postgres: RDS if configured
Storage files: S3 bucket from AWS_S3_BUCKET
```

### Back up root stack

```bash
mkdir -p backups

docker exec -t supabase-db pg_dumpall -U postgres > backups/supabase_$(date +%F_%H%M)_pg_dumpall.sql

tar -czf backups/supabase_storage_$(date +%F_%H%M).tar.gz volumes/storage
```

### Back up generated project

```bash
PROJECT=advanta
mkdir -p projects/$PROJECT/backups

docker exec -t ${PROJECT}-db pg_dumpall -U postgres > projects/$PROJECT/backups/${PROJECT}_$(date +%F_%H%M)_pg_dumpall.sql

tar -czf projects/$PROJECT/backups/${PROJECT}_storage_$(date +%F_%H%M).tar.gz -C projects/$PROJECT volumes/storage
```

### Back up by copying the whole project folder

Stop containers first for a cleaner file-level copy:

```bash
cd projects/advanta
docker compose down
cd ../..
tar -czf advanta_full_project_$(date +%F_%H%M).tar.gz projects/advanta
```

Then restart:

```bash
cd projects/advanta
docker compose up -d
```

### Restore from SQL dump

Example for generated project:

```bash
PROJECT=advanta
cd projects/$PROJECT
docker compose up -d db
cat backups/<dump-file>.sql | docker exec -i ${PROJECT}-db psql -U postgres
```

If restoring to a clean project, restore before exposing it to users.

## AWS production deployment

Use the AWS override when you want:

- S3-backed Supabase Storage
- AWS-friendly networking/load balancer behavior
- Optional RDS Postgres

Read the full guide first:

```text
docs/AWS_DEPLOYMENT.md
```

Basic AWS flow:

```bash
cp .env.aws.example .env
# edit .env with real AWS/RDS/S3/domain values

docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d
```

Important AWS `.env` values:

```env
POSTGRES_HOST=<your-rds-endpoint-or-db>
AWS_REGION=<region>
AWS_S3_BUCKET=<bucket-name>
STORAGE_BACKEND=s3
SUPABASE_PUBLIC_URL=https://api.your-domain.com
API_EXTERNAL_URL=https://api.your-domain.com
SITE_URL=https://your-frontend-domain.com
```

For production, prefer:

- RDS automated backups enabled.
- S3 versioning enabled.
- TLS/HTTPS through ALB, Nginx, Caddy, Traefik, or similar.
- Restricted security groups/firewall rules.
- Strong secrets in AWS Secrets Manager/SSM Parameter Store where possible.

## Environment variables you will commonly edit

| Variable | Purpose |
| --- | --- |
| `POSTGRES_PASSWORD` | Postgres password used by Supabase services. |
| `POSTGRES_HOST` | `db` for local compose DB, or RDS/external hostname. |
| `POSTGRES_PORT` | Host-published PostgreSQL port. |
| `POSTGRES_DB_PORT` | Port used by services to reach PostgreSQL; normally `5432`, or the RDS listener port. |
| `JWT_SECRET` | JWT signing secret. Must match `ANON_KEY` and `SERVICE_ROLE_KEY`. |
| `ANON_KEY` | Public client API key. Safe for browser use, but still respect RLS. |
| `SERVICE_ROLE_KEY` | Admin key. Server-only. Never put in frontend code. |
| `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` | Basic auth for Studio via Kong. |
| `KONG_HTTP_PORT` / `KONG_HTTPS_PORT` | Public API gateway ports. |
| `STUDIO_PORT` | Studio dashboard port. |
| `SUPABASE_PUBLIC_URL` | Public API URL clients/Studio should use. |
| `API_EXTERNAL_URL` | Public Auth API URL. Usually same base as Kong public URL. |
| `SITE_URL` | Main frontend/app URL for auth redirects. |
| `ADDITIONAL_REDIRECT_URLS` | Comma-separated extra allowed auth redirect URLs. |
| `ENABLE_EMAIL_AUTOCONFIRM` | `true` for dev, usually `false` for production email verification. |
| `SMTP_*` | SMTP settings for email auth. |
| `FUNCTIONS_VERIFY_JWT` | Whether Edge Functions require JWT by default. |
| `LOGFLARE_API_KEY` | Analytics/logging key. |
| `DOCKER_SOCKET_LOCATION` | Usually `/var/run/docker.sock` on Linux. |
| `AWS_S3_BUCKET`, `AWS_REGION` | S3 storage settings when using AWS override. |

## Service URLs and ports

For generated projects, ports are written into `projects/<project>/.env`. For the root stack, ports are controlled by `.env`, but Studio is only reachable directly if you publish/proxy the Studio service.

| Service | Typical URL |
| --- | --- |
| Studio | `http://localhost:${STUDIO_PORT}` |
| API gateway / Kong | `http://localhost:${KONG_HTTP_PORT}` |
| REST | `http://localhost:${KONG_HTTP_PORT}/rest/v1/` |
| Auth | `http://localhost:${KONG_HTTP_PORT}/auth/v1/` |
| Storage | `http://localhost:${KONG_HTTP_PORT}/storage/v1/` |
| Realtime | `ws://localhost:${KONG_HTTP_PORT}/realtime/v1/websocket` |
| Edge Functions | `http://localhost:${KONG_HTTP_PORT}/functions/v1/<function-name>` |
| PostgreSQL | `localhost:${POSTGRES_PORT}` |
| Pooler | `localhost:${POOLER_PROXY_PORT_TRANSACTION}` |

See `docs/PORT_REFERENCE.md` for the detailed port reference.

## Common operational commands

Run these inside the project folder (`projects/<project>` or repo root for root stack).

### Check containers

```bash
docker compose ps
```

### Follow logs

```bash
docker compose logs -f
```

Specific service logs:

```bash
docker compose logs -f studio
docker compose logs -f kong
docker compose logs -f auth
docker compose logs -f rest
docker compose logs -f realtime
docker compose logs -f storage
docker compose logs -f db
```

### Restart one service

```bash
docker compose restart studio
```

### Recreate one service after config change

```bash
docker compose up -d --force-recreate studio
```

### Open psql inside Postgres

Root stack:

```bash
docker exec -it supabase-db psql -U postgres
```

Generated project:

```bash
docker exec -it advanta-db psql -U postgres
```

### Test API gateway

```bash
curl -i http://localhost:8000/
```

A `404` at `/` can still mean Kong is running; use actual Supabase paths for real API checks.

### Test Auth health

```bash
docker compose exec auth wget -qO- http://localhost:9999/health
```

### Test Storage health

```bash
docker compose exec storage wget -qO- http://storage:5000/status
```

## Known Supabase Studio browser 404s

Self-hosted Supabase Studio may show browser console errors like:

```text
/api/platform/notifications?offset=0&limit=20&status=new%2Cseen 404
```

This is usually Studio frontend code trying to call Supabase Cloud/platform-only endpoints that do not exist in self-hosted Studio. It is annoying but normally harmless. It does **not** mean Postgres or Storage data is being lost.

If the rest of Studio works, you can usually ignore it. To reduce noise, try upgrading the `supabase/studio` image or handling that path in your reverse proxy.

## Troubleshooting

More detailed guides are in:

- `docs/TROUBLESHOOTING.md`
- `docs/REALTIME_CONFIG.md`
- `docs/PORT_REFERENCE.md`
- `docs/AWS_DEPLOYMENT.md`

### Containers are unhealthy or restarting

```bash
docker compose ps
docker compose logs --tail=200 <service-name>
```

Common services to check first:

```bash
docker compose logs --tail=200 db
docker compose logs --tail=200 kong
docker compose logs --tail=200 auth
docker compose logs --tail=200 realtime
```

### Port already in use

Find the process:

```bash
sudo lsof -i :8000
sudo lsof -i :3000
sudo lsof -i :5432
```

Then either stop the conflicting process or change the port in `.env`.

For generated projects, create with a different base port:

```bash
./supabase_manager.py create advanta2 --base-port 9000
```

### Auth redirects fail

Check these values:

```env
SITE_URL=https://your-frontend-domain.com
ADDITIONAL_REDIRECT_URLS=https://your-other-domain.com,http://localhost:3000
API_EXTERNAL_URL=https://api.your-domain.com
SUPABASE_PUBLIC_URL=https://api.your-domain.com
```

Then recreate Auth/Studio:

```bash
docker compose up -d --force-recreate auth studio
```

### Realtime tenant errors

The Realtime container name is intentionally formatted like:

```yaml
container_name: realtime-dev.supabase-realtime
```

Do not rename it casually. Realtime parses the tenant id from the container hostname. See `docs/REALTIME_CONFIG.md`.

### Storage upload issues

For file backend, verify:

```yaml
volumes/storage:/var/lib/storage
STORAGE_BACKEND=file
FILE_STORAGE_BACKEND_PATH=/var/lib/storage
```

For S3 backend, verify:

```env
STORAGE_BACKEND=s3
AWS_REGION=...
AWS_S3_BUCKET=...
GLOBAL_S3_BUCKET=...
```

Also check bucket permissions and CORS if uploads happen from a browser.

### CORS errors

Check `volumes/api/kong.yml` CORS settings and make sure your frontend domain is allowed. After editing Kong config:

```bash
docker compose up -d --force-recreate kong
```

### Database connection failures

Check:

```env
POSTGRES_HOST=db                 # local root stack
POSTGRES_HOST=<project>-db        # generated project internal hostname
POSTGRES_HOST=<rds-endpoint>      # AWS/RDS
POSTGRES_PORT=5432                # or custom exposed host port
POSTGRES_DB=postgres
POSTGRES_PASSWORD=...
```

Then inspect DB logs:

```bash
docker compose logs --tail=200 db
```

## Repository files

```text
.
├── docker-compose.yml              # base Supabase compose
├── docker-compose.aws.yml          # AWS/S3 override
├── .env.aws.example                # example environment values
├── setup_secure_supabase.sh        # guided secure project setup
├── supabase_manager.py             # project manager CLI
├── supabase_setup.py               # project generator
├── generate_keys.py                # JWT/API key generator
├── update_env_credentials.py       # Studio credential updater
├── update_security.py              # security updater for existing projects
├── sample_security_policies.sql    # example RLS policies
├── security_checklist.md           # security checklist
├── docs/                           # deployment and troubleshooting docs
└── volumes/                        # root-stack config/data bind mounts
```

`projects/`, `.env`, and runtime data folders are ignored because they can contain secrets and database files.
