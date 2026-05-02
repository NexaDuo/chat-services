# Hosting Plan — NexaDuo Chat Services

## Objective
Define the **cheapest possible** hosting strategy (US region), with **100% infrastructure-as-code** (Terraform), simple updates via Docker Compose, and multi-tenant support with **Cloudflare** routing URLs like `https://chat.nexaduo.com/{tenant}/` to Chatwoot.

## Current Repository State
- Stack ready via **docker-compose** with Chatwoot, Evolution API, Dify, Middleware, Postgres+pgvector, and Redis.
- Observability (Prometheus/Grafana) already provisioned.
- Backup via `scripts/backup.sh`.
- External proxy expected (Coolify/Traefik) — no internal nginx.

## Production URLs
- **Coolify:** `coolify.nexaduo.com`
- **Dify:** `dify.nexaduo.com`
- **Chatwoot:** `chat.nexaduo.com`

## Assumptions
- Reference region: **US** (lowest cost comparison).
- **Short maintenance window** accepted for updates (no zero-downtime required).
- Infrastructure declared in **Terraform**.
- Cloudflare used for **path-based tenant routing**.
- Primary recommended provider: **GCP** (lowest estimated cost).

## Cost Comparison (4 vCPU / 16 GB RAM VM, on-demand, Linux, US)
> Source: public dataset from ec2instances.info (Vantage) and equivalents for GCP/Azure. Approx values, excluding disk and egress.

| Provider | VM Type (equivalent) | Region | $/hour | $/month (730h) | Notes |
|---|---|---|---:|---:|---|
| **GCP** | e2-standard-4 | us-central1 | **0.1340** | **97.84** | Cheapest for 4vCPU/16GB |
| **Azure** | D4as v5 (linux-d4asv5-standard) | us-east | **0.1720** | **125.56** | Close to AWS, more expensive than GCP |
| **AWS** | m6i.xlarge | us-east-1 | **0.1920** | **140.16** | Highest cost |

> **Conclusion:** GCP is the lowest-cost choice for the minimum recommended profile (4 vCPU / 16 GB). Azure is a viable alternative; AWS is the most expensive in the same profile.

## Hosting Architecture (Cheap Baseline)
**Strategy:** Single-node VM with Docker Compose.

- **VM**: 4 vCPU / 16 GB RAM / 50–100 GB SSD
- **OS**: Ubuntu 24.04 LTS
- **Network**: 1 Public IP + basic firewall (restricted SSH)
- **Proxy**: Traefik/Coolify on host (or Cloudflare Tunnel)
- **Backup**: Daily cron running `scripts/backup.sh` + upload to cheap storage (GCS/Backblaze/S3)

## Decision Rationale: Coolify
The choice of Coolify as an orchestrator is based on:
- **"Self-Hosted" PaaS Experience (Heroku/Vercel):** Provides a visual interface for container management, environment variables, and SSL (Let's Encrypt) without managed service costs. URL: `coolify.nexaduo.com`.
- **Local/Cloud Parity:** Coolify is open-source and identical in any environment. The same version can run locally (via Docker) for tests identical to production.
- **Resource Efficiency (Docker vs Kubernetes):** Coolify operates on **Docker Engine/Swarm**. Unlike Kubernetes, which has a heavy control plane, Docker allows nearly 100% of the 16GB RAM to be dedicated to applications (Dify, Chatwoot, etc.).
- **Manual vs Automatic Scalability:** To keep costs low, the limitation of **no native auto-scaling** is accepted. Scaling is done vertically (resizing VM) or manually increasing replicas in the panel.

## Application Updates
**Simple Flow (Short Maintenance):**
1. `git pull` on host
2. `docker compose pull` (official images)
3. `docker compose up -d`
4. Quick verification (`docker compose ps`, health checks)

**Update Policy:**
- Update **monthly** (or for critical releases)
- Fixed versioning in `docker-compose.yml`
- Validate tags before deployment

## Multitenancy via Cloudflare
**Objective:** Path-based routing for multiple tenants.

- **Chatwoot:** `https://chat.nexaduo.com/{tenant}/` → Routed to central hub with tenant identifier.
- **Dify:** `https://dify.nexaduo.com/{tenant}/` → Logically isolated access per tenant.

**Strategy:**
- **Cloudflare Workers**: Rewrite the URL to remove the tenant prefix before sending to backend and inject `X-Tenant-Id` header for the middleware.
- The backend (Middleware) uses `X-Tenant-Id` or maps `account_id` from the payload to ensure logical isolation.

## Infrastructure as Code (Terraform)
**GCP MVP:**
- `google_compute_instance` (VM)
- `google_compute_firewall` (SSH + ports 80/443)
- `google_compute_address` (Static IP)
- `google_compute_disk` (SSD)
- `cloudflare_record` (DNS for `coolify`, `chat`, `dify`)

**Suggested Structure:**
```
/infrastructure/terraform
  /modules
    /gcp-vm
    /cloudflare-dns
  /envs
    /production
```

## Implementation Plan (GCP)
- [x] Create GCP Terraform module (VM + network + disk + firewall)
- [x] Create Cloudflare DNS module (A/AAAA + proxied)
- [x] Define variables: domain, zone, VM size, region, SSH key
- [x] Provision VM and validate SSH
- [x] Install Docker + Docker Compose on host
- [x] Initial deploy: `docker compose up -d`
- [x] Configure backups (cron + upload)
- [x] Configure Cloudflare Worker (tenant routing)
- [x] Document update routine

## Notes
- If **zero-downtime** is required, migrate to 2 VMs + L7 proxy (higher cost).
- For growth: separate database (Postgres) to a dedicated VM or managed service.

---
**File created on:** `docs/plans/hosting.plan.md`
