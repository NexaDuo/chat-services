# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2026-04-14)
- [x] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation. (Completed: 2026-04-14)
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-16)
- [ ] **Phase 6: Secret Management & Security Hardening** - Move sensitive data to a self-hosted vault (Infisical) secured via Tailscale. (Current Focus)

## Phase Details

### Phase 6: Secret Management & Security Hardening
**Goal**: Automate secret storage and injection for Terraform and application stacks, eliminating local plain-text files.
**Depends on**: Phase 5
**Requirements**: VAULT-01, VAULT-02, VAULT-03, VAULT-04
**Success Criteria** (what must be TRUE):
  1. Infisical is running and reachable only via Tailscale IP.
  2. Terraform successfully fetches all sensitive variables from Infisical.
  3. `terraform.tfvars` contains zero sensitive data.
**Plans**:
- [ ] 06-01-PLAN.md — Research and deploy Infisical vault via Coolify.
- [ ] 06-02-PLAN.md — Migrate secrets to Infisical and integrate with Terraform provider.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 1/1 | Complete | 2025-01-24 |
| 3. Edge Logic | 2/2 | Complete | 2026-04-14 |
| 4. Automated Provisioning | 3/3 | Complete | 2026-04-14 |
| 5. Core Service Deployment | 5/5 | Complete | 2026-04-16 |
| 6. Secret Management | 0/2 | Planned | - |
