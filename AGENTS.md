# NexaDuo: Agent Instructions & Lessons Learned

This file is the single source of truth for all agents working in this repository.

## Repository Status

This repo is a **fully implemented** production-grade stack. Authority on implementation details lies within the existing source code and this file (which documents architecture and lessons learned).

## Architecture (target state)

The system is a four-service stack with **Chatwoot as the single hub** for all conversations:

```
WhatsApp ──▶ Evolution API ──▶ Chatwoot (Webhook) ──▶ Middleware (Adapter) ──▶ Dify (Agent) ──▶ Azure OpenAI
                                      ▲                      │
                                      └─────── response ─────┘
```

- **Coolify** — [coolify.nexaduo.com](https://coolify.nexaduo.com) (Orquestração e Deploy via Bash/Docker).
- **Chatwoot** — [chat.nexaduo.com](https://chat.nexaduo.com). Inbox, CRM, ticketing, human handoff. Single source of truth.
- **Dify** — [dify.nexaduo.com](https://dify.nexaduo.com). Agentic engine + RAG. Supports MCP bidirectionally.
- **Evolution API v2.1+** — WhatsApp/Instagram bridge.
- **Middleware (Adapter)** — Node.js service that translates Chatwoot webhooks to Dify API calls and sends responses back to Chatwoot. Centralized config provider for internal agents.
- **Self-Healing Agent** — Node.js agent that analyzes Loki logs via Dify to find root causes of errors.
- **Observability** — Loki, Promtail, Prometheus, and Grafana (centralized logs and metrics).
- **Postgres 16+** — shared by Chatwoot, Dify, and Middleware via separate databases.
- **pgvector** — **Primary vector store** (reuses Postgres).
- **Redis 7+** — Sidekiq (Chatwoot) + Celery (Dify) queues.
- **Azure OpenAI** — `gpt-4o` (agent) and `gpt-4o-mini` (embeddings/RAG).

**Human handoff** is a Dify **tool** (HTTP request) that updates the Chatwoot conversation status to `open` and adds the `atendimento-humano` label.

## Deployment Strategy

The stack uses a **Hybrid Deployment Model**:
1. **Foundation (Terraform):** Mature infrastructure components (GCP VM, VPC, Cloudflare Tunnel/DNS, Secrets) are managed via Terraform in `infrastructure/terraform/envs/production/foundation`.
2. **App Layer (Bash/Docker):** Services are deployed directly via `scripts/deploy-tenant-direct.sh`, which uses SCP/SSH to transfer configurations and start Docker Compose on the VM. This bypasses instabilities in the Coolify Terraform provider.

### Standing up (or rebuilding) an environment from scratch

The tenant Terraform layer manages the four Coolify services as **data sources**
keyed by `coolify_service_uuids` (the provider can't UPDATE a service — see the
AVOID list). So the services must pre-exist before `tenant` runs. To provision a
fresh environment (greenfield, or a clean rebuild):

1. Ensure per-env connection secrets exist: `coolify_url_<env>`,
   `coolify_api_token_<env>` (Sanctum `<id>|<plaintext>`), `coolify_destination_uuid_<env>`.
2. `scripts/create-coolify-services.sh <env>` — idempotently creates the Coolify
   project + the 4 compose services (`nexaduo-{shared,chatwoot,dify,app}[-<env>]`)
   and prints the `coolify_service_uuids` HCL map. Re-runs and prod are no-ops.
3. Merge that map into `terraform_tfvars_<env>` (new Secret Manager version).
4. The normal pipeline takes over: `tenant` reads the data sources, applies
   `coolify_service_envs`, and redeploys; then `routes`/`sync`/`onboarding`/`validate`.

A teardown is just the inverse: `DELETE /api/v1/services/<uuid>` for each service
(with `delete_volumes=true`), clear the Postgres bind-mount dir
`/opt/nexaduo/postgres-data` on the VM (it survives volume deletes), and
`terraform state rm` the now-absent managed resources.

## Configuration & Dynamics

The stack uses a **hybrid configuration model**:
1. **Static (.env):** Infrastructure secrets (DB passwords, Redis URLs, etc.).
2. **Dynamic (Postgres + Middleware API):** Application-specific settings and API keys (e.g., `DIFY_SELF_HEALING_API_KEY`).

**Standard for internal agents:**
- All internal agents (like `self-healing`) must fetch their functional configuration from the **Middleware Config API** (`GET /config`).
- Authentication for internal config fetching is done via `Bearer token` using the `HANDOFF_SHARED_SECRET`.
- New configuration keys should be added to the `middleware.configs` table in Postgres for runtime updates.

## Target Repo Layout

```
docker-compose.yml           # Base stack
.env.example                 # Secrets template
/deploy                      # Multi-stack docker-compose configurations
/middleware                  # Dify-Chatwoot Adapter (Node.js/TS)
/infrastructure/postgres     # Init: DB creation + pgvector extension
/infrastructure/terraform    # Foundation and Tenant IaC
/dify-apps                   # DSL (YAML) exports of agents - MUST be versioned
/provisioning                # Automation scripts
/scripts                     # Deploy utilities
/onboarding                  # Playwright automation and smoke tests
```

## Reproducibility is Non-Negotiable

**Every fix lands in code so a from-scratch rebuild reproduces it.** Postgres now
lives on a dedicated disk with a daily `pg_dump` to GCS (bootstrap section 3e /
`scripts/vm-backup.sh`), so **tearing the environment down and re-bootstrapping is
a safe, acceptable cost** — always prefer a clean, code-driven rebuild over
accumulating manual drift.

- **No fix exists until it is in IaC.** Config, schema/tenant seeds, runtime
  tweaks — all corrections MUST go through versioned Terraform, the deploy
  workflow, or the bootstrap/deploy scripts. A change that only lives on the VM
  does not exist as far as the next deploy is concerned.
- **Manual VM intervention is a stopgap, never the fix.** If you touch the VM by
  hand to unblock, backfill that change into code (script/workflow) in the same
  session. A green deploy that is only green because of an out-of-band manual
  step is a red deploy waiting to happen. Real examples that bit us:
  - Promtail config reached the host but a running promtail never reloaded it
    (single-file bind-mount + `rm -rf`/`mv` inode swap) → the deploy went green
    while the fix was inert. Fixed by a checksum-gated restart in bootstrap 3c.
  - The `tenants` table was seeded by hand but the pipeline tunneled to a
    `localhost:5432` where nothing listens (Postgres is docker-network-only) and
    used a placeholder `*_database_url` secret → seed via `docker exec psql`
    instead (see `sync` job / `scripts/sync-tenants.ts --print-sql`).
- **Prefer rebuild over drift.** When a fix is hard to apply idempotently to the
  running stack, it is legitimate to re-bootstrap from code — backups make the
  data recoverable.

## SRE Auditor Agent & Routine Audits

To facilitate routine inspections and prevent infrastructure drift, this repository includes a workspace agent skill called **`sre-auditor`** located in [.agents/skills/sre-auditor/SKILL.md](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.agents/skills/sre-auditor/SKILL.md).

Whenever you need to run routine verification, ask the agent to **"run a routine SRE audit"** or **"inspect stack health"**. The agent will:
1. Run [health-check-all.sh](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/health-check-all.sh) to diagnose application layers, network connectivity, and ports.
2. Check container states and health statuses (`docker ps -a`).
3. Scan logs for known pattern anomalies (e.g., Redis memory overcommit, database locks, Loki query status errors).
4. File structured issues on GitHub (`gh issue create`) for tracked resolutions.

## Operational Non-Negotiables

- **RAM:** **16 GB minimum** recommended for the shared stack.
- **Backup:** daily `pg_dump` (all DBs) to GCS via `scripts/vm-backup.sh` (root
  cron 03:00, installed by `bootstrap-coolify.sh` 3e); `/dify-apps` backed up via
  Git. Postgres is on a **dedicated disk** (`attached_disk` inline on the VM).
- **Observability:** Grafana + Prometheus for queue depths and **token usage per account_id**.
- **Rate limiting:** Respect Meta tiers; throttle in Dify.

## Deployment Strategies to AVOID

- **Coolify Terraform Provider for Service Stacks:** Extremely brittle. Fails with `422 Unprocessable Content` on updates to immutable fields like `environment_name`, even with `ignore_changes`. Use for `foundation` only.
- **Coolify Dynamic Routing for Multi-Container Stacks:** Unreliable for complex setups (Dify, NexaDuo Stack). Routes often 404 or 502 after redeploys. Use deterministic fallback YAMLs in `/data/coolify/proxy/dynamic/`.
- **Relative Volume Paths in Coolify Compose:** Causes resolution errors (containers stuck in `Created`). Use absolute paths or fixed host variables like `/opt/nexaduo`.
- **Hardcoded Localhost in Tests:** Production tests must use environment variables (`CHATWOOT_URL`, etc.) to support both local and remote validation.
- **Coolify Status Tracking:** Coolify tracks resource health using specific labels (`coolify.managed`, `coolify.serviceId`, `coolify.service.subName`) and container names (UUIDs). Manual deployments must match these.
- **Container Entrypoints:** Images like Chatwoot require explicit entrypoints (`docker/entrypoints/rails.sh`) to start correctly; otherwise, they might default to an interactive shell (`irb`).
- **Cloudflare SSL Loops:** Behind Cloudflare Tunnels, disabling `FORCE_SSL` in applications is often necessary to prevent infinite redirect loops.

## Recommended Workflow

1. **Foundation:** Terraform (Official GCP/Cloudflare providers).
2. **App Layer:** Scripted `scp` of `.env`/`compose` + `ssh docker compose up -d`.
3. **Routing:** Scripted generation of Traefik dynamic configs.
4. **Validation:** Playwright tests with production URLs.

## Terminology Constraints

- **NexaDuo Name:** NexaDuo is the name of only one of the tenants in this multi-tenant stack, not the stack itself. Do not use "NexaDuo" as a generic name for the platform or the admin dashboard. Reference the platform or system generically as "Multitenant Chat Services" or "Omnichannel Stack".

## Diretrizes de Release, Deploy e Acompanhamento de Workflows

- **Fases Obrigatórias no Plano:** Todo plano de implementação deve obrigatoriamente conter etapas claras para:
  1. Deploy em Staging.
  2. Validação E2E/Fumaça em Staging.
  3. Deploy em Produção.
  4. Validação E2E/Fumaça em Produção.
- **Monitoramento Ativo de Workflows:** O agente não deve considerar a tarefa concluída apenas ao abrir o PR ou fazer o push. Ele deve monitorar a execução dos workflows do GitHub Actions (via logs, comandos `gh run watch` ou checagens no Git) até que o deploy em staging e produção seja concluído com sucesso.
- **Validação com URLs Reais:** A validação final em staging e produção deve ser feita executando os testes automatizados (como os testes do Playwright) apontando para as URLs de produção/staging correspondentes, e nunca apenas localmente.
- **Testes de Regressão no Playwright:** Sempre que um bug for corrigido (como falhas de autenticação, sessões expiradas ou roteamento), adicione um teste ou asserção correspondente no Playwright para evitar regressões futuras (ex: monitorar chamadas de rede como `/console/api/refresh-token` para capturar erros inesperados após a autenticação).

## Lições Aprendidas: Migrações de Banco de Dados em Ambientes Existentes

- **Atualização de Esquema (Schema Changes):** Arquivos de bootstrap como `01-init.sql` só rodam na primeira inicialização do container (quando o volume do Postgres está vazio). Para ambientes existentes em staging/produção, as migrações de esquema (como novas tabelas, colunas ou índices) devem ser aplicadas manualmente no container de banco de dados do respectivo host para evitar que o deploy quebre por falta de tabelas no banco de dados.
- **Como Executar Migrações Manuais na VM:**
  1. Conecte-se na VM via SSH (ex: `gcloud compute ssh`).
  2. Encontre o container ativo do Postgres:
     `sudo docker ps --filter name=^/postgres-`
  3. Execute os comandos SQL necessários no banco de dados desejado:
     `sudo docker exec -i <container-name> psql -U postgres -d middleware < migration.sql`



