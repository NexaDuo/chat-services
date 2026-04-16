# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2026-04-14)
- [x] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation. (Completed: 2026-04-14)
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-16)
- [x] **Phase 6: Secret Management & Security Hardening** - Move sensitive data to GCP Secret Manager for centralized and secure handling. (Completed: 2026-04-16)

## Phase Details

### Phase 6: Secret Management & Security Hardening
**Goal**: Automate secret storage and injection for Terraform and application stacks, eliminating local plain-text files.
**Completed**: 2026-04-16
**Success Criteria** (what must be TRUE):
  1. GCP Secret Manager API is enabled and accessible. (PASSED)
  2. Terraform successfully fetches all sensitive variables from GCP Secret Manager. (PASSED)
  3. `terraform.tfvars` contains zero sensitive data. (PASSED)
  4. Local development parity is achieved via `sync-secrets-gcp.sh`. (PASSED)
**Plans**:
- [x] .planning/quick/20260416-harden-secret-management/PLAN.md — Migrate to GCP Secret Manager.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 1/1 | Complete | 2025-01-24 |
| 3. Edge Logic | 2/2 | Complete | 2026-04-14 |
| 4. Automated Provisioning | 3/3 | Complete | 2026-04-14 |
| 5. Core Service Deployment | 5/5 | Complete | 2026-04-16 |
| 6. Secret Management | 1/1 | Complete | 2026-04-16 |
