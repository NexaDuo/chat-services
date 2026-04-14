# Technology Stack

**Analysis Date:** 2026-04-14

## Languages

**Primary:**
- TypeScript 5.x - Middleware and Self-healing agent.
- HCL (HashiCorp Configuration Language) - Terraform for GCP and Cloudflare.

**Secondary:**
- SQL - PostgreSQL migrations and queries.
- Bash - Provisioning and backup scripts.

## Runtime

**Environment:**
- Node.js 20+ (Dockerized)
- Docker Engine / Docker Compose (via Coolify)

**Package Manager:**
- pnpm (Middleware, Agents)
- Lockfile: `pnpm-lock.yaml` (present)

## Frameworks

**Core:**
- Fastify (Middleware API)
- Terraform (IaC)

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
- `SierraJC/coolify` (Terraform provider)
- `cloudflare/cloudflare` (Terraform provider)
- `hashicorp/google` (Terraform provider)

## Configuration

**Environment:**
- Managed via `.env` (secrets) and `terraform.tfvars` (infrastructure settings).
- Middleware uses Zod to validate and parse environment variables.

**Build:**
- Docker multi-stage builds for TypeScript components.
- Terraform remote state stored in GCS (`nexaduo-terraform-state`).

## Platform Requirements

**Development:**
- Docker, Node.js, pnpm, Terraform CLI, gcloud CLI.

**Production:**
- GCP Compute Engine (e2-standard-4) with Ubuntu 22.04.

---

*Stack analysis: 2026-04-14*
