# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2026-04-14)
- [x] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation. (Completed: 2026-04-14)
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-16)
- [x] **Phase 6: Secret Management & Security Hardening** - Move sensitive data to GCP Secret Manager for centralized and secure handling. (Completed: 2026-04-16)
- [ ] **Phase 7: Repository Hardening for Public Release** - Address security audit findings (rotate secrets, remove fallbacks, webhook auth, image pinning) before making the repo public. (Planned)

## Phase Details

### Phase 6: Secret Management & Security Hardening
**Goal**: Centralize secrets in GCP Secret Manager.
**Plans**:
- [x] .planning/quick/20260416-harden-secret-management/PLAN.md — Migrate to GCP Secret Manager.

### Phase 7: Repository Hardening for Public Release
**Goal**: Remove all committed secrets and insecure defaults to allow for safe public GitHub release.
**Target Completion**: 2026-04-17
**Plans**:
- [ ] .planning/phases/07-repository-hardening/07-01-PLAN.md — Global Secret Scrubbing & Image Pinning.
- [ ] .planning/phases/07-repository-hardening/07-02-PLAN.md — Webhook Security & Ingress Hardening.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 1/1 | Complete | 2025-01-24 |
| 3. Edge Logic | 2/2 | Complete | 2026-04-14 |
| 4. Automated Provisioning | 3/3 | Complete | 2026-04-14 |
| 5. Core Service Deployment | 5/5 | Complete | 2026-04-16 |
| 6. Secret Management | 1/1 | Complete | 2026-04-16 |
| 7. Repository Hardening | 0/2 | In-Progress | - |
