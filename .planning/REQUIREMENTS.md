# Requirements: NexaDuo Chat Services

## Infrastructure (INFRA)
- **INFRA-01**: Provision GCP Compute Instance (e2-standard-4) using Terraform.
- **INFRA-02**: Configure GCP Networking (VPC, Firewall for SSH/HTTP/S, Static IP) via Terraform.
- **INFRA-03**: Provision Persistent SSD Storage (50-100GB) via Terraform.
- **INFRA-04**: Install and initialize Coolify v4 on the provisioned VM.
- **INFRA-05**: Implement automated backup rotation to GCS (Google Cloud Storage).

## Routing & Edge (ROUTE)
- **ROUTE-01**: Configure Cloudflare DNS with wildcard subdomain support (`*.chat.nexaduo.com`).
- **ROUTE-02**: Implement Cloudflare Worker for subdomain-based tenant identification.
- **ROUTE-03**: Inject `X-Tenant-ID` header at the edge for backend consumption.
- **ROUTE-04**: Secure origin by restricting access to Cloudflare IPs or using Cloudflare Tunnels.

## Application Deployment (DEPLOY)
- **DEPLOY-01**: Orchestrate Chatwoot, Dify, and Evolution API using Coolify/Docker Compose.
- **DEPLOY-02**: Configure Chatwoot for subdomain-based multi-tenancy (resolving subpath issues).
- **DEPLOY-03**: Deploy the Middleware bridge to handle Chatwoot-Dify communication.
- **DEPLOY-04**: Deploy Observability stack (Prometheus/Grafana) within the same environment.

## Multi-tenancy & Provisioning (PROV)
- **PROV-01**: Define a standardized tenant configuration schema.
- **PROV-02**: Automate DNS record creation for new tenants via Terraform.
- **PROV-03**: Automate Cloudflare Worker routing table updates for new tenants.

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 1 | Pending |
| INFRA-02 | Phase 1 | Pending |
| INFRA-03 | Phase 1 | Pending |
| INFRA-04 | Phase 2 | Pending |
| INFRA-05 | Phase 2 | Pending |
| ROUTE-01 | Phase 2 | Pending |
| ROUTE-02 | Phase 3 | Pending |
| ROUTE-03 | Phase 3 | Pending |
| ROUTE-04 | Phase 2 | Pending |
| DEPLOY-01 | Phase 4 | Pending |
| DEPLOY-02 | Phase 4 | Pending |
| DEPLOY-03 | Phase 4 | Pending |
| DEPLOY-04 | Phase 4 | Pending |
| PROV-01 | Phase 5 | Pending |
| PROV-02 | Phase 5 | Pending |
| PROV-03 | Phase 5 | Pending |
