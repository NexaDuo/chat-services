# Project State: NexaDuo Chat Services

## Project Reference

**Core Value:** Low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API via Coolify and Cloudflare.
**Current Focus:** Coolify management and Cloudflare Tunnels.

## Current Position

**Phase:** Phase 4 (Core Service Deployment)
**Plan:** Full stack deployment on GCP (Chatwoot, Dify, Evolution, Middleware)
**Status:** Complete
**Progress:** [||||||||||] 100%

## Performance Metrics
- **Total Requirements:** 16
- **Requirement Coverage:** 100% (16/16)
- **Phase Completion:** 4/5
- **Plan Completion:** 1/1

## Accumulated Context

### Decisions
- 2025-01-24: Initial pivot to subdomain-based routing (`{tenant}.chat.nexaduo.com`) to avoid potential Chatwoot subpath breakages.
- 2026-04-14: **Final Architectural Choice:** Transition back to **path-based routing** (`chat.nexaduo.com/{tenant}/` and `dify.nexaduo.com/{tenant}`) to simplify infrastructure management and unify domains. This will be achieved via advanced Cloudflare Worker logic at the edge to handle the necessary path-to-tenant-ID mapping.
- 2025-01-24: Adopt GCP as primary hosting provider using e2-standard-4 instances for cost-efficiency.
- 2025-01-24: Orchestrate with Coolify v4 to simplify multi-container management.
- 2025-01-24: Secure ingress via Cloudflare Tunnels (Argo) for "portless" origin architecture.
- 2025-01-24: Remote state management via GCS bucket `nexaduo-terraform-state`.
- 2025-01-24: Implement dynamic tenant mapping in Middleware via Postgres `tenants` table.
- 2025-01-24: Postpone Cloudflare Worker (Phase 3) to focus on full stack deployment (Phase 4).
- 2026-04-14: Cloudflare Tunnel configured with Host Networking on GCP VM to enable correct origin routing.
- 2026-04-14: Temporary direct IP access (3000, 3001, 8000) allowed in GCP firewall for onboarding while Cloudflare SSL propagates.
- 2026-04-14: Standardized tenant routing to `chat.nexaduo.com/{tenant}/` and `dify.nexaduo.com/{tenant}`.

### Roadmap Evolution
- Phase 6 added: as configuracoes no coolify podem ser gerenciadas em codigo? se sim, vamos adicionar uma fase para fazer esse setup

### Todos
- [x] Create Terraform directory structure
- [x] Implement `gcp-vm` module (VPC, Subnet, Firewall, E2 Instance)
- [x] Implement `cloudflare-dns` module (Root & Wildcard records)
- [x] Set up `production` environment configuration
- [x] Provision infrastructure (GCP VM + DNS)
- [x] Configure GCS remote state backend
- [x] Verify Coolify accessibility and initial setup
- [x] Deploy Shared Infrastructure (Postgres, Redis) in Coolify.
- [x] Deploy Chatwoot (Rails, Sidekiq) in Coolify.
- [x] Deploy Dify (API, Worker, Web, Sandbox) in Coolify.
- [x] Deploy Middleware and Evolution API in Coolify.
- [ ] Implement Cloudflare Worker for subdomain routing (Deferred).

### Blockers
- None.

## Session Continuity
- **Next Step:** Manual onboarding via public IP/domain and verify Cloudflare SSL propagation.
- **Focus:** Application onboarding and multi-tenancy verification.
