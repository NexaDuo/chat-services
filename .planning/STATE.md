# Project State: NexaDuo Chat Services

## Project Reference

**Core Value:** Low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API via Coolify and Cloudflare.
**Current Focus:** Phase 3: Edge Logic & Path Routing (Cloudflare Workers)

## Current Position

**Phase:** Phase 3 (Edge Logic & Path Routing)
**Status:** In Progress
**Progress:** [|||||     ] 50%

## Performance Metrics
- **Total Requirements:** 16
- **Requirement Coverage:** 100% (16/16)
- **Phase Completion:** 3/5
- **Plan Completion:** 0/1

## Accumulated Context

### Decisions
- 2026-04-14: **Final Architectural Choice:** Transition back to **path-based routing** (`chat.nexaduo.com/{tenant}/` and `dify.nexaduo.com/{tenant}`) to simplify infrastructure management and unify domains. This will be achieved via advanced Cloudflare Worker logic at the edge to handle the necessary path-to-tenant-ID mapping.
- 2026-04-14: Phase 5 (Core Service Deployment) was manually completed as a PoC; now need to retroactively implement Phase 3 (Edge Logic) to support the final multi-tenant architecture before automating provisioning.
- 2026-04-14: Chose **Hono** framework for the Cloudflare Worker for its performance and clean middleware support.
- 2026-04-14: Implemented **HTMLRewriter** in the Worker to dynamically fix absolute asset paths (`/assets/` -> `/{tenant}/assets/`) without origin modifications.

### Todos
- [x] Research Cloudflare Worker path-based routing patterns.
- [x] Initialize Cloudflare Worker project with Hono.
- [x] Implement Worker logic for header injection (`X-Tenant-ID`) and path stripping.
- [x] Implement HTMLRewriter for asset path fixing.
- [ ] Define shared secret for Worker-to-Middleware authentication (currently placeholder).
- [ ] Configure Cloudflare Worker routes for `chat.nexaduo.com` and `dify.nexaduo.com`.
- [ ] Verify WebSocket compatibility through the Worker.

## Session Continuity
- **Next Step:** Configure Cloudflare Worker routes and deploy the worker to production.
- **Focus:** Edge Logic & Path Routing Deployment.
