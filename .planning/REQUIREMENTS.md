# Requirements: NexaDuo Chat Services

## Infrastructure (INFRA)
- **INFRA-01**: Provision GCP Compute Instance (e2-standard-4) using Terraform.
- **INFRA-02**: Configure GCP Networking (VPC, Firewall for SSH/HTTP/S, Static IP) via Terraform.
- **INFRA-03**: Provision Persistent SSD Storage (50-100GB) via Terraform.
- **INFRA-04**: Install and initialize Coolify v4 on the provisioned VM.
- **INFRA-05**: Implement automated backup rotation to GCS (Google Cloud Storage).
- **INFRA-06**: Automate Coolify v4 application and service configuration via Terraform/API.

## Routing & Edge (ROUTE)
- **ROUTE-01**: Configure Cloudflare DNS for unified subdomains (`chat.nexaduo.com`, `dify.nexaduo.com`).
- **ROUTE-02**: Implement Cloudflare Worker for path-based tenant identification (`/tenant/`).
- **ROUTE-03**: Inject `X-Tenant-ID` header at the edge for backend consumption.
- **ROUTE-04**: Secure origin by restricting access to Cloudflare IPs.
- **ROUTE-05**: Implement Cloudflare Tunnels (Argo) to provide portless ingress to the origin.

## Application Deployment (DEPLOY)
- **DEPLOY-01**: Orchestrate Chatwoot, Dify, and Evolution API using Coolify/Docker Compose.
- **DEPLOY-02**: Configure Chatwoot and Dify for path-based multi-tenancy via Cloudflare Workers.
- **DEPLOY-03**: Deploy the Middleware bridge to handle Chatwoot-Dify communication.
- **DEPLOY-04**: Deploy full observability stack (Prometheus, Grafana, Loki, Promtail, OTEL Collector) for monitoring and log aggregation.
- **DEPLOY-05**: Implement Self-Healing Agent to autonomously analyze service logs and diagnose root causes.
- **DEPLOY-06**: Enable seamless human handoff from AI agents to Chatwoot operators via Middleware.

## Multi-tenancy & Provisioning (PROV)
- **PROV-01**: Define a standardized tenant configuration schema.
- **PROV-02**: Automate DNS record creation for new tenants via Terraform.
- **PROV-03**: Automate Cloudflare Worker routing table updates for new tenants.

## Secret Management (VAULT)
- **VAULT-01**: Securely store all infrastructure and application secrets in GCP Secret Manager (Single Source of Truth).
- **VAULT-02**: Eliminate local `.tfvars` files for sensitive data in local and production environments.
- **VAULT-03**: Integrate GCP Secret Manager with Terraform for automatic secret injection into Coolify.
- **VAULT-04**: Sync GCP Secret Manager with local `.env` via scripts for consistent development.
- **VAULT-05**: Secure secret access using GCP IAM (Service Accounts) and local user authentication.

## Repository Hardening (HARD)
- **HARD-01**: Rotate and remove hardcoded secrets from tracked files (env examples, wrangler configs).
- **HARD-02**: Remove insecure credential fallbacks and enforce fail-fast behavior in code and scripts.
- **HARD-03**: Implement Chatwoot webhook authentication to verify incoming requests.
- **HARD-04**: Pin all container images to immutable versions in Docker Compose.
- **HARD-05**: Restrict origin network access (ports, CORS, plugin signature verification).

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 1 | Completed |
| INFRA-02 | Phase 1 | Completed |
| INFRA-03 | Phase 1 | Completed |
| INFRA-04 | Phase 2 | Completed |
| INFRA-05 | Phase 2 | Completed |
| ROUTE-01 | Phase 2 | Completed |
| ROUTE-02 | Phase 3 | Completed |
| ROUTE-03 | Phase 3 | Completed |
| ROUTE-04 | Phase 2 | Completed |
| ROUTE-05 | Phase 2 | Completed |
| DEPLOY-01 | Phase 5 | Completed |
| DEPLOY-02 | Phase 5 | Completed |
| DEPLOY-03 | Phase 5 | Completed |
| DEPLOY-04 | Phase 5 | Completed |
| DEPLOY-05 | Phase 5 | Completed |
| DEPLOY-06 | Phase 5 | Completed |
| PROV-01 | Phase 4 | Completed |
| PROV-02 | Phase 4 | Completed |
| PROV-03 | Phase 4 | Completed |
| INFRA-06 | Phase 5 | Completed |
| VAULT-01 | Phase 6 | Completed |
| VAULT-02 | Phase 6 | Completed |
| VAULT-03 | Phase 6 | Completed |
| VAULT-04 | Phase 6 | Completed |
| VAULT-05 | Phase 6 | Completed |
| HARD-01 | Phase 7 | Planned |
| HARD-02 | Phase 7 | Planned |
| HARD-03 | Phase 7 | Planned |
| HARD-04 | Phase 7 | Planned |
| HARD-05 | Phase 7 | Planned |
