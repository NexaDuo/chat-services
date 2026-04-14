# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code.
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access.
- [x] **Phase 3: Edge Logic & Subdomain Routing** - Implement Cloudflare Workers for header injection and multi-tenant routing.
- [x] **Phase 4: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration.
- [ ] **Phase 5: Automated Provisioning** - Automate tenant lifecycle management and resource allocation.

## Phase Details

### Phase 1: Foundation (Terraform & GCP)
**Goal**: Establish a reproducible, cost-effective infrastructure baseline on Google Cloud Platform.
**Depends on**: Nothing
**Requirements**: INFRA-01, INFRA-02, INFRA-03
**Success Criteria** (what must be TRUE):
  1. GCP Compute Instance (e2-standard-4) is provisioned and accessible via SSH.
  2. VPC and Firewall rules restrict all non-essential ingress traffic.
  3. Persistent SSD storage is successfully attached and ready for application data.
**Plans**: 1 plan
- [x] 01-01-PLAN.md — Provision core GCP infrastructure.

### Phase 2: Management & Edge Connectivity
**Goal**: Install the orchestration layer and establish secure, portless connectivity to Cloudflare.
**Depends on**: Phase 1
**Requirements**: INFRA-04, INFRA-05, ROUTE-01, ROUTE-04
**Success Criteria** (what must be TRUE):
  1. Coolify v4 dashboard is accessible via a secure Cloudflare-managed domain.
  2. All ingress traffic to the GCP VM flows exclusively through Cloudflare Tunnels.
  3. Wildcard DNS records (`*.chat.nexaduo.com`) are configured and pointing to Cloudflare.
**Plans**: 3 plans
- [ ] 02-01-PLAN.md — Coolify Initialization & Hardening.
- [ ] 02-02-PLAN.md — Cloudflare Edge Connectivity.
- [ ] 02-03-PLAN.md — Backup Automation.

### Phase 3: Edge Logic & Subdomain Routing
**Goal**: Implement tenant identification and routing logic at the network edge to support multiple tenants.
**Depends on**: Phase 2
**Requirements**: ROUTE-02, ROUTE-03
**Success Criteria** (what must be TRUE):
  1. Request to `alpha.chat.nexaduo.com` results in `X-Tenant-ID: alpha` header reaching the origin.
  2. Cloudflare Worker successfully maps subdomains to the corresponding origin services.
  3. Edge logic correctly handles WebSocket upgrades for Chatwoot's real-time features.
**Plans**: TBD

### Phase 4: Automated Core Service Deployment
**Goal**: Deploy and verify the full application stack (Chatwoot, Dify, Middleware, Observability) using Terraform/IaC to ensure a reproducible, multi-tenant-ready environment.
**Depends on**: Phase 3
**Requirements**: DEPLOY-01, DEPLOY-02, DEPLOY-03, DEPLOY-04, INFRA-06
**Success Criteria** (what must be TRUE):
  1. Chatwoot, Dify, and Middleware are fully functional (including assets and WebSockets).
  2. The complete application stack is provisioned via `terraform apply` (no manual UI setup).
  3. Observability dashboards (Grafana) show live metrics from all deployed services.
**Plans**: 1 plan
- [x] [04-PLAN.md](.planning/phases/04-core-service-deployment/04-PLAN.md) — Automated core service deployment.

### Phase 5: Automated Provisioning
**Goal**: Streamline the onboarding of new tenants through automated infrastructure updates.
**Depends on**: Phase 4
**Requirements**: PROV-01, PROV-02, PROV-03
**Success Criteria** (what must be TRUE):
  1. Adding a tenant to a central configuration file and running a provisioning script creates all DNS/Edge records.
  2. A new tenant can access their isolated environment within minutes of provisioning.
  3. Automated backups are verified and restorable for specific tenant data.
**Plans**: TBD

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 0/3 | In Progress | - |
| 3. Edge Logic | 0/1 | Not started | - |
| 4. Core Service Deployment | 1/1 | Complete | 2026-04-14 |
| 5. Automated Provisioning | 0/1 | Not started | - |
