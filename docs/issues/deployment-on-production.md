# Production Deployment — Issues and Solutions

## Current State (2026-04-19)
- VM running: `136.115.211.240`
- Coolify: healthy, but outdated token in Secret Manager
- Cloudflare Tunnel: configured and functional
- Coolify Services (nexaduo-shared, chatwoot, dify, nexaduo-app): **not deployed yet**

---

## Issues Fixed in Code

### 1. Redis — Invalid Command Argument
**File:** `deploy/docker-compose.shared.yml`

The YAML list format was passing `--requirepass VALUE` as a single argument to redis-server. Fixed by separating into distinct items:
```yaml
# BEFORE (wrong)
- --requirepass ${REDIS_PASSWORD}

# AFTER (correct)
- --requirepass
- ${REDIS_PASSWORD}
```

### 2. Postgres Init SQL — Relative Path Not Working in Coolify
**File:** `deploy/docker-compose.shared.yml`

Coolify receives the compose file as a string and doesn't have access to the local `./01-init.sql` file. Fixed by using an absolute path:
```yaml
# BEFORE
- ./01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro

# AFTER
- /opt/nexaduo/postgres/01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
```
The file is uploaded to the VM via `gcloud compute scp --tunnel-through-iap` by a `null_resource` in Terraform.

### 3. Cloudflare Tunnel — Traefik Bypass Broke WebSockets
**File:** `infrastructure/terraform/modules/cloudflare-tunnel/main.tf`

`chat` and `dify` were pointing directly to containers, bypassing Traefik. WebSockets (Chatwoot Action Cable) were failing. Fixed by routing everything through the VM's public IP on port 80:
```hcl
# BEFORE
service = "http://nexaduo-chatwoot-rails:3000"

# AFTER
service = "http://${var.vm_ip}:80"  # via Traefik
```

---

## Structural Issue: Deployment Not Reproducible

### Root Cause
Coolify is installed from scratch on every new VM. With each installation:
- A new **API token** is generated
- A new **destination_uuid** is assigned to the server

Terraform uses these values via GCP Secret Manager, but they become outdated after each recreation.

### Proposed Solution: 3 Phases + Bootstrap Script

**Phase 1 — Infrastructure (Terraform targets)**
```bash
terraform apply -auto-approve \
  -target=module.vm \
  -target=module.tunnel \
  -target=module.dns_chat \
  -target=module.dns_dify \
  -target=module.backup_storage
```

**Phase 2 — Coolify Bootstrap (`scripts/bootstrap-coolify.sh`)**
Script that should:
1. Wait for `http://VM_IP:8000/api/v1/version` to respond (polling with retry)
2. Use default Coolify credentials to generate an API token via API
3. Capture the local server's `destination_uuid`
4. Update both in GCP Secret Manager:
   ```bash
   echo -n "$TOKEN" | gcloud secrets versions add coolify_api_token \
     --project nexaduo-492818 --data-file=-
   echo -n "$UUID" | gcloud secrets versions add coolify_destination_uuid \
     --project nexaduo-492818 --data-file=-
   ```
5. Send `01-init.sql` to the VM via IAP with retry (IAP takes ~30s to register the instance)
6. Create the Docker network: `docker network create nexaduo-network`

**Phase 3 — Coolify Services**
```bash
terraform apply -auto-approve
```

**Orchestrator: `scripts/deploy-production.sh`**
```bash
#!/bin/bash
set -e
cd infrastructure/terraform/envs/production
terraform apply -auto-approve -target=module.vm -target=module.tunnel \
  -target=module.dns_chat -target=module.dns_dify -target=module.backup_storage
../../scripts/bootstrap-coolify.sh
terraform apply -auto-approve
```

---

## Immediate Action to Unblock HTTP 404 on FQDNs

When `chat.nexaduo.com`, `dify.nexaduo.com`, and `coolify.nexaduo.com` return 404 even with healthy containers and `service_applications.fqdn` populated in the Coolify database, execute:

```bash
./scripts/refresh-coolify-routes.sh
```

The script:
1. Locates the actual Chatwoot, Dify, and Coolify containers via `coolify.service.subName` labels.
2. Generates `/data/coolify/proxy/dynamic/nexaduo-routes.yaml` with explicit `Host(...)` routing.
3. Restarts `coolify-proxy`.
4. Validates local routing (`Host` header) and public HTTPS URLs.

To customize project/zone/VM/domain:

```bash
PROJECT_ID=nexaduo-492818 \
ZONE=us-central1-b \
VM_NAME=nexaduo-chat-services \
BASE_DOMAIN=nexaduo.com \
./scripts/refresh-coolify-routes.sh
```

---

## Known Bug: Coolify Provider v0.10.2

The `SierraJC/coolify v0.10.2` provider returns 422 when attempting to update an existing service because it includes read-only fields (`server_uuid`, `project_uuid`, etc.) in the request body.

**Applied Workaround:** `ignore_changes = [compose]` in `coolify_service.shared`. Changes to the shared stack compose must be applied manually via the Coolify UI.

---

*Last updated: 2026-04-19*
