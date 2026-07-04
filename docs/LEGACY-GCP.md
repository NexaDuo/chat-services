# LEGACY (GCP / Coolify era) — archived reference only

> **Dead since GCP was decommissioned (`b02aa74`, 2026-06-30).** None of this
> applies to the live runtime, which is a **host-local Docker Compose stack served
> by the Cloudflare tunnel** (see [`AGENTS.md`](../AGENTS.md)). Kept only for a
> possible future cloud restore. Do not act on anything here for the running stack.

## Legacy deployment model (GCP)
1. **Foundation (Terraform):** GCP VM, VPC, Cloudflare Tunnel/DNS, Secrets in
   `infrastructure/terraform/envs/production/foundation`. Only the Cloudflare
   resources (tunnel/DNS) survived GCP loss; the GCP resources do not apply.
2. **App Layer (Bash/Docker):** `scripts/deploy-tenant-direct.sh` SCP/SSH'd configs
   to the VM; the `deploy.yml` pipeline orchestrated it. Dead until a cloud target
   exists again. `deploy.yml` / `power.yml` are kept `workflow_dispatch`-only stubs.

## Standing up / rebuilding a GCP+Coolify environment from scratch
The tenant Terraform layer managed the four Coolify services as **data sources**
keyed by `coolify_service_uuids` (the provider can't UPDATE a service). Services
had to pre-exist before `tenant` ran:
1. Ensure per-env secrets: `coolify_url_<env>`, `coolify_api_token_<env>` (Sanctum
   `<id>|<plaintext>`), `coolify_destination_uuid_<env>`.
2. `scripts/create-coolify-services.sh <env>` — idempotently creates the Coolify
   project + 4 compose services and prints the `coolify_service_uuids` HCL map.
3. Merge that map into `terraform_tfvars_<env>` (new Secret Manager version).
4. Pipeline: `tenant` reads data sources, applies `coolify_service_envs`, redeploys;
   then `routes`/`sync`/`onboarding`/`validate`.

Teardown: `DELETE /api/v1/services/<uuid>` (with `delete_volumes=true`) per service,
clear the Postgres bind-mount `/opt/nexaduo/postgres-data` on the VM, and
`terraform state rm` the absent resources.

## Coolify deployment strategies to AVOID (dead — Coolify not used in host-local runtime)
- **Coolify Terraform Provider for service stacks:** brittle; `422 Unprocessable
  Content` on immutable fields (`environment_name`) even with `ignore_changes`.
- **Coolify dynamic routing for multi-container stacks:** unreliable; 404/502 after
  redeploys. Used deterministic fallback YAMLs in `/data/coolify/proxy/dynamic/`.
- **Relative volume paths in Coolify compose:** containers stuck in `Created`; used
  absolute paths / `/opt/nexaduo`.
- **Coolify status tracking:** required specific labels (`coolify.managed`,
  `coolify.serviceId`, `coolify.service.subName`) + UUID container names.

## Legacy GCP operational notes
- **Backup:** `scripts/vm-backup.sh` did a daily `pg_dump` to
  `gs://nexaduo-coolify-backups/...`. Replaced by `scripts/backup-host.sh`.
- **Postgres disk:** a dedicated `google_compute_disk` guarded by `prevent_destroy`
  + daily snapshots. On 2026-06-25 a `pd-balanced` `type` change recreated it
  **blank** and wiped production Chatwoot — **never change a force-new disk
  attribute** (durable lesson; see memory `prod-data-loss-2026-06-25`). Recovered
  from the GCS dump.
- **DR restore path:** dumps at `gs://nexaduo-coolify-backups/...`, restored via
  `gsutil cat | zcat | docker exec psql` after `gcloud compute snapshots create`.
- **DB schema break-glass:** `gcloud compute ssh <vm>` (IAP) →
  `sudo docker exec -i <pg> psql -U postgres < infrastructure/postgres/01-init.sql`.

## Legacy recommended workflow (GCP)
1. Foundation: Terraform (GCP/Cloudflare providers).
2. App layer: scripted `scp` of `.env`/compose + `ssh docker compose up -d`.
3. Routing: scripted Traefik dynamic configs.
4. Validation: Playwright with production URLs.
