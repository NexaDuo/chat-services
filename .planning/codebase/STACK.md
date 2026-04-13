# Technology Stack

**Analysis Date:** 2025-01-24

## Languages

**Primary:**
- TypeScript 5.x - Used in `middleware/` and `agents/self-healing/`
- Node.js >= 22.0.0 - Execution environment for custom services

**Secondary:**
- Ruby on Rails (Chatwoot) - Core inbox hub
- Python (Dify) - Agent/RAG engine
- SQL (PostgreSQL 16) - Shared persistence layer
- Shell (Bash/Sh) - Provisioning and scripts

## Runtime

**Environment:**
- Docker / Docker Compose - Primary deployment and orchestration environment

**Package Manager:**
- npm (Node.js)
- Lockfile: `package-lock.json` present in `middleware/` and `agents/self-healing/`

## Frameworks

**Core:**
- Fastify 5.x - Web framework for `middleware/`
- Dify 1.13.x - LLM application framework and RAG engine

**Testing:**
- Not explicitly configured with a common runner (e.g., Jest/Vitest) in the manifests, though type checking with `tsc` is present.

**Build/Dev:**
- TypeScript Compiler (tsc) - Build process for Node.js services
- tsx / ts-node - Development runners for Node.js services

## Key Dependencies

**Critical:**
- `pg` 8.x - PostgreSQL client used across custom services
- `axios` 1.7.x - HTTP client for service-to-service communication (Middleware ⇄ Dify, Agent ⇄ Loki)
- `zod` 3.23.x - Schema validation for incoming webhooks in `middleware/`
- `pino` 9.x - High-performance logging for custom services

**Infrastructure:**
- `prom-client` 15.1.x - Prometheus metrics collection in `middleware/`
- `pgvector` - PostgreSQL extension for vector similarity search (used by Dify)

## Configuration

**Environment:**
- `.env` file based on `.env.example` - Centralized environment configuration
- Docker Compose environment variables - Service discovery and linking

**Build:**
- `tsconfig.json` - Found in `middleware/` and `agents/self-healing/`

## Platform Requirements

**Development:**
- Docker & Docker Compose
- Node.js 22+ (for local development of middleware/agents)

**Production:**
- Any Linux platform supporting Docker
- Recommended: 8GB+ RAM to support the full stack (Chatwoot, Dify, and Observability)

---

*Stack analysis: 2025-01-24*
