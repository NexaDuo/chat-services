# Research Summary: NexaDuo Chat Services Multi-tenancy

**Project:** NexaDuo Chat Services Infrastructure
**Date:** 2025-01-24
**Status:** Research Complete

## Executive Summary

The NexaDuo Chat Services platform aims to provide a robust, multi-tenant AI-driven chat environment leveraging **Chatwoot** and **Dify**. Research indicates that while the applications are powerful, their multi-tenancy implementations have specific constraints—most notably a strong dependency on root-level or subdomain-based routing. Attempting to force path-based routing (e.g., `/tenant/app`) for these services, particularly Chatwoot, introduces significant technical debt, broken assets, and WebSocket failures.

The recommended architectural approach is a **Hybrid Edge-Origin Architecture**. This uses **Cloudflare Workers** at the edge to handle tenant identification and header injection (`X-Tenant-ID`), **Cloudflare Tunnels** for secure, portless ingress, and **Coolify** (hosted on **Hetzner ARM**) as the orchestration layer. This stack provides the best balance of low cost (~€12/mo vs ~$100/mo on GCP), high performance, and ease of management.

## Key Findings

### 1. Technology Stack & Infrastructure
*   **Hosting:** **Hetzner ARM (CAX21/31)** is the clear winner for cost-efficiency, offering similar performance to GCP e2-standard-4 at roughly 10% of the cost.
*   **Management:** **Coolify v4** is recommended for application orchestration over pure manual Docker Compose or Kubernetes, as it provides a self-hosted PaaS experience with built-in Traefik management.
*   **Security:** Cloudflare Tunnels (Argo) should be used to eliminate open public ports, exposing the origin only to Cloudflare's edge.

### 2. Multi-tenancy & Routing Conflict
*   **The Conflict:** The initial plan for path-based routing (`https://chat.nexaduo.com/{tenant_id}/app`) directly conflicts with the architectural design of Chatwoot and Dify.
    *   **Chatwoot:** Extremely brittle on subpaths; assets and ActionCable (WebSockets) frequently break.
    *   **Dify:** Next.js base paths are set at **build-time**, meaning a single Docker image cannot easily serve multiple tenants on different paths without complex rebuilding.
*   **The Resolution:** Pivot to **subdomain-based routing** (`{tenant}.chat.nexaduo.com`). Cloudflare Workers can still inject the `X-Tenant-ID` header based on the subdomain to simplify backend middleware logic.

### 3. Critical Pitfalls
*   **Resource Spikes:** Dify's vector databases and Sidekiq workers can cause OOM (Out of Memory) errors on 8GB instances. A minimum of 4GB swap space is required.
*   **Header Trust:** The middleware must verify that `X-Tenant-ID` headers originate from the Cloudflare Worker (via a shared secret) to prevent spoofing.

## Roadmap Implications

### Suggested Phase Structure

1.  **Phase 1: Base Infrastructure (The "Foundation")**
    *   **Goal:** Setup Hetzner VPS, Coolify, and Cloudflare connectivity.
    *   **Rationale:** Establishes the secure "portless" origin.
    *   **Pitfall Avoidance:** Configure 4GB+ Swap immediately to prevent OOM kills during initial builds.

2.  **Phase 2: Core Service Deployment (Subdomain-First)**
    *   **Goal:** Deploy Chatwoot and Dify using subdomain-based routing.
    *   **Rationale:** Validates that assets and WebSockets work natively before adding routing complexity.
    *   **Features:** Subdomain isolation, SSL via Cloudflare/Coolify.

3.  **Phase 3: Edge Routing & Tenant Identification**
    *   **Goal:** Implement Cloudflare Workers to handle `X-Tenant-ID` injection and routing logic.
    *   **Rationale:** Decouples tenant identification from the application logic, allowing the Middleware to stay "tenant-aware" but "URL-agnostic."

4.  **Phase 4: Automated Provisioning**
    *   **Goal:** Use Coolify API and Terraform to automate the creation of new tenant environments.
    *   **Rationale:** Scales the platform from manual setup to "instant provisioning."

### Research Flags
*   **Needs Research:** The specific Coolify API endpoints for programmatically spinning up Docker Compose stacks (Phase 4).
*   **Standard Patterns:** Cloudflare Tunnel and Worker header injection are well-documented and can skip deep research.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| **Stack (Hetzner/ARM)** | HIGH | Pricing and performance data for 2025 is very stable. |
| **Routing (Subdomains)** | HIGH | Strong community consensus that subpaths break Chatwoot. |
| **Architecture** | MEDIUM | Requires careful configuration of Cloudflare Workers to ensure "Upgrade" headers for WebSockets are preserved. |
| **Pitfalls** | HIGH | Documented issues in GitHub/Community forums are consistent. |

### Gaps to Address
*   **Terraform/Coolify Sync:** Further investigation into how much of the Coolify configuration can be managed via Terraform vs. the Coolify API.
*   **Dify Multi-tenant Limits:** Better understanding of how many Dify "applications" can run on a single instance before hitting resource ceilings.

## Sources
*   [Hetzner Cloud Pricing (Jan 2025)](https://www.hetzner.com/cloud)
*   [GCP Pricing Calculator](https://cloud.google.com/products/calculator)
*   [Chatwoot Deployment Guide: Subpaths](https://www.chatwoot.com/docs/deployment/)
*   [Dify Environment Configuration](https://docs.dify.ai/deployment/docker-compose)
*   [Coolify Documentation: Cloudflare Tunnels](https://coolify.io/docs/cloudflare)
