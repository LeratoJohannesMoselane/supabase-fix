# Troubleshooting Guide

Common issues and solutions for Supabase self-hosted deployment, with special focus on cloud deployments.

## Table of Contents
- [Realtime Issues](#realtime-issues)
- [CORS Errors](#cors-errors)
- [Storage and S3 Issues](#storage-and-s3-issues)
- [DNS and Networking Issues](#dns-and-networking-issues)
- [Load Balancer Issues](#load-balancer-issues)
- [Database Connection Issues](#database-connection-issues)
- [Authentication Issues](#authentication-issues)
- [Studio Snippets Issues](#studio-snippets-issues)
- [Container Startup Issues](#container-startup-issues)

---

## Realtime Issues

### Issue: "Tenant not found" Error in Realtime Container

**Symptoms:**
```
[error] Tenant not found: realtime-dev
[error] Could not find tenant configuration
```

**Root Cause:**
Realtime service parses the tenant ID from the container's subdomain. The container name MUST follow the pattern: `realtime-dev.{project-name}-realtime`

**Solution:**

1. **Check your container name** in `docker-compose.yml`:
   ```yaml
   realtime:
     container_name: realtime-dev.supabase-realtime  # CORRECT
     # NOT: supabase-realtime or realtime
   ```

2. **Verify the pattern:**
   - First part: `realtime-dev` (this is your tenant ID)
   - Middle part: `.` (required separator)
   - Last part: `{project-name}-realtime` (your project name + `-realtime`)

3. **Ensure the database has matching tenant:**
   ```sql
   -- Check if tenant exists
   SELECT * FROM _realtime.tenants WHERE name = 'realtime-dev';

   -- If missing, it should be created automatically on first container start
   -- If not, check container logs for initialization errors
   ```

4. **Verify healthcheck URL** matches tenant name:
   ```yaml
   healthcheck:
     test:
       - "CMD"
       - "curl"
       - "-sSfL"
       - "http://localhost:4000/api/tenants/realtime-dev/health"
   ```

**Prevention:**
Always use the provided `supabase_setup.py` script which ensures correct container naming.

---

### Issue: DNS Errors in Kong Logs When Connecting to Realtime

**Symptoms:**
```
[error] DNS resolution failed for realtime
[error] failed to get upstream: host not found
[error] no resolver defined to resolve 'realtime'
```

**Root Cause:**
Kong cannot resolve container names due to Docker DNS configuration issues in cloud environments.

**Solution:**

1. **Add DNS search domain to Kong** in `docker-compose.yml`:
   ```yaml
   kong:
     environment:
       KONG_DNS_ORDER: LAST,A,CNAME
     dns_search: .  # Add this line
   ```

2. **Verify all services are on same Docker network:**
   ```bash
   docker network inspect supabase_default
   # Should list all supabase containers
   ```

3. **Test DNS resolution from Kong container:**
   ```bash
   docker exec supabase-kong ping -c 1 realtime-dev.supabase-realtime
   docker exec supabase-kong nslookup auth
   docker exec supabase-kong nslookup storage
   ```

4. **Alternative: Use explicit network** in `docker-compose.yml`:
   ```yaml
   networks:
     supabase-network:
       driver: bridge

   services:
     kong:
       networks:
         - supabase-network
     realtime:
       networks:
         - supabase-network
     # ... all other services
   ```

---

### Issue: WebSocket Connection Fails for Realtime

**Symptoms:**
- Client shows: `WebSocket connection failed`
- Browser console: `Error during WebSocket handshake`
- Connection closes immediately after opening

**Solution:**

1. **Enable sticky sessions on load balancer:**
   - AWS ALB: Enable "Stickiness" on target group (duration: 86400 seconds)
   - Nginx: Use `ip_hash` directive
   - Traefik: Use sticky sessions label

2. **Verify WebSocket headers are forwarded** in Kong config:
   ```yaml
   # In kong.yml realtime service
   - name: cors
     config:
       headers:
         - sec-websocket-extensions
         - sec-websocket-key
         - sec-websocket-version
   ```

3. **Check if Kong supports WebSocket protocol:**
   ```yaml
   realtime:
     protocol: ws  # Ensure this is set
     url: http://realtime-dev.supabase-realtime:4000/socket
   ```

4. **Test WebSocket connectivity:**
   ```bash
   # Using wscat
   npm install -g wscat
   wscat -c "ws://your-domain.com/realtime/v1/websocket?apikey=YOUR_ANON_KEY&vsn=1.0.0"
   ```

---

## CORS Errors

### Issue: CORS Error - Missing Headers

**Symptoms:**
```
Access to fetch at 'https://api.your-domain.com/storage/v1/object' from origin
'https://your-app.com' has been blocked by CORS policy: Request header field
'prefer' is not allowed by Access-Control-Allow-Headers in preflight response.
```

**Root Cause:**
Default Kong CORS configuration is missing headers required by Supabase client libraries.

**Solution:**

1. **Update kong.yml with complete CORS headers:**

   For **Storage service** (most headers needed):
   ```yaml
   - name: storage-v1
     plugins:
       - name: cors
         config:
           origins:
             - "https://your-frontend-domain.com"
             - "http://localhost:3000"  # For development
           methods:
             - GET
             - POST
             - PUT
             - PATCH
             - DELETE
             - HEAD
             - OPTIONS
           headers:
             - Accept
             - Authorization
             - Content-Type
             - apikey
             - x-client-info
             - accept-profile
             - content-profile
             - prefer
             - x-upsert
             - tus-resumable
             - upload-metadata
             - x-source
             - upload-length
             - upload-offset
             - cache-control
           exposed_headers:
             - location
             - tus-resumable
             - upload-offset
             - upload-length
           credentials: true
           max_age: 3600
   ```

   For **REST API** (PostgREST):
   ```yaml
   - name: rest-v1
     plugins:
       - name: cors
         config:
           origins:
             - "https://your-frontend-domain.com"
           headers:
             - accept-profile
             - content-profile
             - prefer
             - x-upsert
             - Authorization
             - apikey
             - x-client-info
           credentials: true
   ```

2. **For multiple origins**, use array syntax:
   ```yaml
   origins:
     - "https://app.your-domain.com"
     - "https://staging.your-domain.com"
     - "http://localhost:3000"
     - "http://localhost:3001"
   ```

3. **For wildcard subdomains** (use with caution):
   ```yaml
   origins:
     - "https://*.your-domain.com"
   ```

4. **Restart Kong after changes:**
   ```bash
   docker restart supabase-kong
   ```

---

### Issue: CORS Error - Multiple origins not working

**Symptoms:**
- CORS works for one domain but not others
- Error: "The 'Access-Control-Allow-Origin' header contains multiple values"

**Root Cause:**
Kong CORS plugin can only return one origin in the `Access-Control-Allow-Origin` header, but it will match against the list and return the requesting origin if it's in the allowed list.

**Solution:**

The CORS plugin correctly handles multiple origins by:
1. Checking the incoming `Origin` header
2. If it matches one in the `origins` list, return that specific origin
3. This is correct CORS behavior

If you're still seeing issues:

1. **Verify your origins list is complete:**
   ```yaml
   origins:
     - "https://app.example.com"
     - "https://admin.example.com"
     - "http://localhost:3000"
   ```

2. **Check for trailing slashes** (don't include them):
   ```yaml
   origins:
     - "https://app.example.com"      # ✅ Correct
     # NOT: "https://app.example.com/" # ❌ Wrong
   ```

3. **Ensure protocol matches**:
   ```yaml
   origins:
     - "https://app.example.com"  # ✅ For production
     - "http://localhost:3000"    # ✅ For development
   ```

---

## Storage and S3 Issues

### Issue: S3 Upload Fails with "Access Denied"

**Symptoms:**
```
Error uploading file: AccessDenied: Access Denied
Status: 403
```

**Solution:**

1. **Verify IAM permissions:**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:PutObject",
           "s3:DeleteObject",
           "s3:ListBucket"
         ],
         "Resource": [
           "arn:aws:s3:::your-bucket-name/*",
           "arn:aws:s3:::your-bucket-name"
         ]
       }
     ]
   }
   ```

2. **Check S3 bucket policy:**
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "AllowSupabaseStorage",
         "Effect": "Allow",
         "Principal": {
           "AWS": "arn:aws:iam::YOUR-ACCOUNT-ID:role/YOUR-EC2-ROLE"
         },
         "Action": [
           "s3:GetObject",
           "s3:PutObject",
           "s3:DeleteObject"
         ],
         "Resource": "arn:aws:s3:::your-bucket-name/*"
       }
     ]
   }
   ```

3. **Verify storage environment variables:**
   ```bash
   STORAGE_BACKEND=s3
   AWS_REGION=us-east-1
   AWS_S3_BUCKET=your-bucket-name
   # storage-api v1.7x names (legacy GLOBAL_S3_* names still work as fallbacks)
   STORAGE_S3_BUCKET=your-bucket-name
   STORAGE_S3_REGION=us-east-1
   STORAGE_S3_FORCE_PATH_STYLE=false  # false for AWS S3
   ```

4. **Check if using IAM role (recommended) or access keys:**
   ```bash
   # Using IAM role (preferred - leave these empty):
   AWS_ACCESS_KEY_ID=
   AWS_SECRET_ACCESS_KEY=

   # Using access keys (not recommended for production):
   AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
   AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
   ```

5. **Test S3 access from storage container:**
   ```bash
   docker exec supabase-storage env | grep AWS
   docker exec supabase-storage env | grep S3
   ```

---

### Issue: File Upload Works But Image Transformation Fails

**Symptoms:**
- Files upload successfully to S3
- Accessing images through `/storage/v1/object/public/...` works
- Image transformations (resize, format) return errors

**Solution:**

1. **Verify ImgProxy has S3 access:**
   ```yaml
   imgproxy:
     environment:
       IMGPROXY_USE_S3: "true"
       IMGPROXY_S3_REGION: us-east-1
       AWS_ACCESS_KEY_ID: ${AWS_ACCESS_KEY_ID}
       AWS_SECRET_ACCESS_KEY: ${AWS_SECRET_ACCESS_KEY}
   ```

2. **Check ImgProxy logs:**
   ```bash
   docker logs supabase-imgproxy
   ```

3. **Ensure ImgProxy can reach S3:**
   ```bash
   docker exec supabase-imgproxy wget -O - https://your-bucket.s3.amazonaws.com/
   ```

---

## DNS and Networking Issues

### Issue: Services Can't Communicate Internally

**Symptoms:**
```
Error: connect ECONNREFUSED
Failed to connect to http://auth:9999
```

**Solution:**

1. **Verify all services are on same network:**
   ```bash
   docker network inspect supabase_default | grep Name
   ```

2. **Check service health:**
   ```bash
   docker ps
   docker-compose ps
   ```

3. **Test inter-service connectivity:**
   ```bash
   # From Kong to Auth
   docker exec supabase-kong curl http://auth:9999/health

   # From Kong to Storage
   docker exec supabase-kong curl http://storage:5000/status
   ```

4. **Restart Docker network:**
   ```bash
   docker-compose down
   docker network prune
   docker-compose up -d
   ```

---

## Load Balancer Issues

### Issue: ALB Health Check Failing

**Symptoms:**
- ALB shows targets as "Unhealthy"
- Can't access application through ALB
- Direct access to EC2 instance works

**Common Causes & Solutions:**

1. **Wrong health check path:**
   ```
   Health Check Path: /
   Success Codes: 404  # Kong returns 404 for root, which is OK!
   ```

2. **Security group blocking traffic:**
   ```
   EC2 Security Group Inbound Rules:
   - Port 8000 from ALB Security Group ✅
   ```

3. **Kong not listening on 8000:**
   ```bash
   docker exec supabase-kong netstat -tulpn | grep 8000
   ```

4. **Kong container not running:**
   ```bash
   docker ps | grep kong
   docker logs supabase-kong
   ```

5. **Wrong target port in target group:**
   ```
   Target Group Port: 8000 (NOT 80, NOT 443)
   ```

---

### Issue: 502 Bad Gateway from Load Balancer

**Symptoms:**
- ALB returns 502 error
- Services work when accessing EC2 directly

**Solution:**

1. **Check Kong logs:**
   ```bash
   docker logs supabase-kong --tail=100
   ```

2. **Verify target health:**
   ```bash
   # From EC2
   curl http://localhost:8000
   # Should return Kong 404 response
   ```

3. **Check if Kong can reach backend services:**
   ```bash
   docker exec supabase-kong curl http://auth:9999/health
   docker exec supabase-kong curl http://rest:3000
   ```

4. **Verify security groups allow outbound from ALB to EC2:8000**

---

## Database Connection Issues

### Issue: "Too many connections" Error

**Symptoms:**
```
FATAL: sorry, too many clients already
Error: remaining connection slots are reserved
```

**Solution:**

1. **Use connection pooler (Supavisor):**
   ```
   Connection String:
   postgresql://postgres:password@your-host:6543/postgres
   # Note: Port 6543 (pooler), not 5432 (direct)
   ```

2. **Increase PostgreSQL max_connections** (if using local DB):
   ```sql
   ALTER SYSTEM SET max_connections = 200;
   SELECT pg_reload_conf();
   ```

3. **Increase pooler pool size:**
   ```bash
   # In .env
   POOLER_DEFAULT_POOL_SIZE=40  # Increase from 20
   POOLER_MAX_CLIENT_CONN=200   # Increase from 100
   ```

4. **Use RDS Proxy** (if using AWS RDS):
   - Update `POSTGRES_HOST` to RDS Proxy endpoint
   - RDS Proxy handles connection pooling automatically

---

## Authentication Issues

### Issue: Email Confirmation Links Don't Work

**Symptoms:**
- Users receive confirmation emails
- Clicking link shows error or redirects incorrectly

**Solution:**

1. **Verify redirect URLs are configured:**
   ```bash
   # In .env
   SITE_URL=https://your-app.com
   ADDITIONAL_REDIRECT_URLS=https://staging.your-app.com,http://localhost:3000
   ```

2. **Check mailer URL paths:**
   ```bash
   MAILER_URLPATHS_CONFIRMATION="/auth/v1/verify"
   ```

3. **Verify API_EXTERNAL_URL:**
   ```bash
   API_EXTERNAL_URL=https://api.your-domain.com  # Your ALB or API endpoint
   ```

4. **Test email template variables:**
   ```bash
   docker logs supabase-auth | grep "Sending email"
   ```

---

## Studio Snippets Issues

### Issue: "SNIPPETS_MANAGEMENT_FOLDER env var is not set"

**Symptoms:**

- Studio logs contain:

  ```text
  Error: SNIPPETS_MANAGEMENT_FOLDER env var is not set. Please set it to use snippets properly.
      at ... /api/platform/project/default/snippets
  ```

- The SQL Editor sidebar shows no snippets, saving a snippet fails, or the
  Snippets panel shows an error toast.
- Saved snippets disappear after `docker compose down && docker compose up`.

**Why it happens:**

Supabase Studio only enables snippets when the container gets
`SNIPPETS_MANAGEMENT_FOLDER`, and it persists the snippet library in the file
`$SNIPPETS_MANAGEMENT_FOLDER/snippets.json`. Both the variable and a writable bind
mount are required:

```yaml
services:
  studio:
    environment:
      SNIPPETS_MANAGEMENT_FOLDER: /app/snippets
      EDGE_FUNCTIONS_MANAGEMENT_FOLDER: /app/edge-functions
    volumes:
      - ./volumes/snippets:/app/snippets:z
      - ./volumes/functions:/app/edge-functions:ro,z
```

Older projects generated by `supabase_setup.py` shipped a `studio` service without
those keys, and the `volumes/snippets` directory is often missing from the deploy
folder. When the directory is absent, Docker creates it root-owned, and Studio then
fails to write `snippets.json` even though the env var is set.

**Solution:**

1. **Patch the project (idempotent, backs up the compose file):**

   ```bash
   python3 update_studio_snippets.py --project-path projects/<project>
   # or for every project plus the root stack
   python3 update_studio_snippets.py --root . --all-projects
   ```

2. **Verify and restart Studio:**

   ```bash
   cd projects/<project>
   python3 ../../update_studio_snippets.py --check    # prints [OK] once fixed
   docker compose up -d studio
   docker compose logs --tail=50 studio
   ```

3. **Check the host directory is writable by the Studio process:**

   ```bash
   ls -ld volumes/snippets
   # If Studio runs as a non-root user and the dir is root-owned, either chown it:
   sudo chown -R "$(id -u):$(id -g)" volumes/snippets
   # ...or let the helper open it up:
   python3 ../../update_studio_snippets.py --project-path . --fix-permissions
   ```

4. **Confirm from inside the container:**

   ```bash
   docker compose exec studio sh -c 'echo "$SNIPPETS_MANAGEMENT_FOLDER"; ls -ld /app/snippets; touch /app/snippets/.write-test && echo writable'
   ```

**Notes:**

- `SNIPPETS_MANAGEMENT_FOLDER` is a path *inside* the container; it is not read from
  the `.env` file, so there is no `SNIPPETS_MANAGEMENT_FOLDER=` line to add to `.env`.
  Setting it only in `.env` has no effect.
- Snippets are stored as a JSON file, not in Postgres, so back them up by copying
  `volumes/snippets/` (or with `scripts/backup.sh` / `make backup`, which now include a
  `*_snippets.tar.gz` artifact) rather than with `pg_dump`.
- `EDGE_FUNCTIONS_MANAGEMENT_FOLDER` is mounted read-only, matching upstream. Studio can
  then browse edge function source but cannot save edits from the dashboard; make the
  `studio` mount writable (`./volumes/functions:/app/edge-functions:z`) to enable that.
- Upstream tracks the poor UX of the missing variable in [supabase/supabase#44220](https://github.com/supabase/supabase/issues/44220).

---

## Container Startup Issues

### Issue: Containers Exiting Immediately

**Symptoms:**
```bash
docker ps  # Shows fewer containers than expected
docker ps -a  # Shows containers with "Exited (1)" status
```

**Solution:**

1. **Check logs for the failing container:**
   ```bash
   docker logs supabase-auth
   docker logs supabase-storage
   ```

2. **Common causes:**
   - **Missing environment variables:**
     ```bash
     docker-compose config | grep POSTGRES_PASSWORD
     # Ensure all required vars are set
     ```

   - **Database not ready:**
     ```yaml
     # Ensure depends_on with condition: service_healthy
     depends_on:
       db:
         condition: service_healthy
     ```

   - **Port conflicts:**
     ```bash
     sudo lsof -i :8000  # Check if port is already in use
     ```

3. **Restart in correct order:**
   ```bash
   docker-compose down
   docker-compose up -d db      # Start database first
   sleep 10                      # Wait for init
   docker-compose up -d          # Start all services
   ```

---

## Quick Diagnostic Commands

```bash
# Check all container statuses
docker-compose ps

# View logs for all services
docker-compose logs -f

# View logs for specific service
docker logs supabase-kong --tail=100 -f

# Check container health
docker inspect supabase-db | grep Health -A 10

# Test service endpoints
curl http://localhost:8000  # Kong (should return 404)
curl http://localhost:8000/health  # Also try /health

# Check network connectivity
docker network inspect supabase_default

# Restart specific service
docker-compose restart kong

# Full restart
docker-compose down && docker-compose up -d
```

---

## Getting Help

If you're still experiencing issues:

1. **Gather information:**
   ```bash
   # Container status
   docker-compose ps > debug.txt

   # Logs from all services
   docker-compose logs >> debug.txt

   # Environment (sanitize secrets first!)
   docker-compose config >> debug.txt
   ```

2. **Check existing issues:**
   - [GitHub Issues](https://github.com/supabase/supabase/issues)
   - [Official Discord](https://discord.supabase.com)

3. **Create detailed bug report including:**
   - Your deployment environment (AWS EC2, DigitalOcean, etc.)
   - Docker and docker-compose versions
   - Relevant logs
   - What you've already tried

---

## Related Documentation

- [Port Reference](./PORT_REFERENCE.md) - All service ports explained
- [AWS Deployment](./AWS_DEPLOYMENT.md) - Step-by-step AWS setup
- [Realtime Configuration](./REALTIME_CONFIG.md) - Deep dive into Realtime setup
- [CORS Configuration](./CORS_CONFIGURATION.md) - Comprehensive CORS guide
- [Storage S3 Setup](./STORAGE_S3.md) - Complete S3 integration guide
