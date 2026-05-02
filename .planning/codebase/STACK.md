# Technology Stack

**Analysis Date:** 2026-05-02

## Languages

**Primary:**
- TypeScript 5.x - Middleware and Self-healing agent.
- HCL (HashiCorp Configuration Language) - Terraform for GCP and Cloudflare.

**Secondary:**
- SQL - PostgreSQL migrations and queries.
- Bash - Provisioning, deployment, and backup scripts.

## Runtime

**Environment:**
- Node.js 22+ (Dockerized)
- Docker Engine / Docker Compose (managed via Hybrid Scripted Deployment)

**Package Manager:**
- npm (Onboarding)
- pnpm (Middleware, Agents)
- Lockfile: `pnpm-lock.yaml` (present)

## Frameworks

**Core:**
- Fastify (Middleware API)
- Terraform (IaC - Foundation Layer)

**Infrastructure:**
- GCP (Google Cloud Platform)
- Cloudflare (Edge, Tunnel, DNS)

**Core Applications:**
- Chatwoot (Customer Service)
- Dify (AI Agent Orchestration)
- Evolution API (Messaging bridge)

## Key Dependencies

**Critical:**
- `pg` (PostgreSQL client)
- `zod` (Schema validation)
- `axios` (HTTP client for Chatwoot/Dify integration)

**Infrastructure:**
- `cloudflare/cloudflare` (Terraform provider)
- `hashicorp/google` (Terraform provider)
- `docker compose` (Application orchestration)

## Configuration

**Environment:**
- Managed via `.env` (secrets), `terraform.tfvars` (infrastructure), and GCP Secret Manager (Source of Truth for production).
- Middleware uses Zod to validate and parse environment variables.

**Build:**
- Docker multi-stage builds for TypeScript components.
- Terraform remote state stored in GCS (`nexaduo-terraform-state`).

## Platform Requirements

**Development:**
- Docker, Node.js, pnpm, Terraform CLI, gcloud CLI.

**Production:**
- GCP Compute Engine (e2-standard-4) with Ubuntu 24.04.

---

*Stack analysis: 2026-05-02*
