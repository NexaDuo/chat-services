# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2025-01-24)
- [ ] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation.
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-14)

## Phase Details

### Phase 1: Foundation (Terraform & GCP)
**Goal**: Establish a reproducible, cost-effective infrastructure baseline on Google Cloud Platform.
**Depends on**: Nothing
**Requirements**: INFRA-01, INFRA-02, INFRA-03
**Success Criteria** (what must be TRUE):
  1. GCP Compute Instance (e2-standard-4) is provisioned and accessible via SSH.
  2. VPC and Firewall rules restrict all non-essential ingress traffic.
  3. Persistent SSD storage is successfully attached and ready for application data.

### Phase 2: Management & Edge Connectivity
**Goal**: Install the orchestration layer and establish secure, portless connectivity to Cloudflare.
**Depends on**: Phase 1
**Requirements**: INFRA-04, INFRA-05, ROUTE-01, ROUTE-04
**Success Criteria** (what must be TRUE):
  1. Coolify v4 dashboard is accessible via a secure Cloudflare-managed domain.
  2. All ingress traffic to the GCP VM flows exclusively through Cloudflare Tunnels.
  3. DNS records are configured and pointing to Cloudflare.

### Phase 3: Edge Logic & Path Routing
**Goal**: Implement tenant identification and routing logic at the network edge to support multiple tenants via paths.
**Depends on**: Phase 2
**Requirements**: ROUTE-02, ROUTE-03
**Success Criteria** (what must be TRUE):
  1. Request to `chat.nexaduo.com/alpha/` results in `X-Tenant-ID: alpha` header reaching the origin.
  2. Cloudflare Worker successfully maps paths to the corresponding origin services.
  3. Edge logic correctly handles WebSocket upgrades for Chatwoot's real-time features.

### Phase 4: Automated Provisioning
**Goal**: Streamline the onboarding of new tenants through automated infrastructure updates.
**Depends on**: Phase 3
**Requirements**: PROV-01, PROV-02, PROV-03
**Success Criteria** (what must be TRUE):
  1. Adding a tenant to a central configuration file and running a provisioning script creates all DNS/Edge records.
  2. A new tenant can access their isolated environment within minutes of provisioning.
  3. Automated backups are verified and restorable for specific tenant data.
**Plans**: TBD

### Phase 5: Core Service Deployment
**Goal**: Deploy and verify the full application stack in a multi-tenant-ready environment.
**Depends on**: Phase 4
**Requirements**: DEPLOY-01, DEPLOY-02, DEPLOY-03, DEPLOY-04
**Success Criteria** (what must be TRUE):
  1. Chatwoot is fully functional (including assets and WebSockets) under a tenant-specific path.
  2. Dify is accessible and able to communicate with the Middleware bridge.
  3. Observability dashboards (Grafana) show live metrics from all deployed services.
**Plans**: [05-PLAN.md](.planning/phases/05-core-service-deployment/05-PLAN.md)

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 1/1 | Complete | 2025-01-24 |
| 3. Edge Logic | 1/1 | Complete | 2025-01-24 |
| 4. Automated Provisioning | 0/1 | Not started | - |
| 5. Core Service Deployment | 1/1 | Complete | 2026-04-14 |
