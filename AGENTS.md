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
- **Evolution API v2.1+** — **WhatsApp-only** bridge. (It does NOT support Instagram in any version — the `integration` enum is `WHATSAPP-BAILEYS`/`WHATSAPP-BUSINESS`/`EVOLUTION`. Instagram is handled by Chatwoot's **native** channel via Meta/Instagram-Login OAuth, independent of Evolution — see issue #31.)
- **Middleware (Adapter)** — Node.js service that translates Chatwoot webhooks to Dify API calls and sends responses back to Chatwoot. Centralized config provider for internal agents.
- **Self-Healing Agent** — Node.js agent that analyzes Loki logs via Dify to find root causes of errors.
- **Observability** — Loki, Promtail, Prometheus, and Grafana (centralized logs and metrics).
- **Postgres 16+** — shared by Chatwoot, Dify, and Middleware via separate databases.
- **pgvector** — **Primary vector store** (reuses Postgres).
- **Redis 7+** — Sidekiq (Chatwoot) + Celery (Dify) queues.
- **Azure OpenAI** — `gpt-4o` (agent) and `gpt-4o-mini` (embeddings/RAG).

**Human handoff** is a Dify **tool** (HTTP request) that updates the Chatwoot conversation status to `open` and adds the `atendimento-humano` label.

## Deployment Strategy

> **Current reality (since commit `b02aa74`, 2026-06-30): GCP is decommissioned.**
> There is no cloud VM, no Secret Manager, no GCS, and no WIF. The GitHub Actions
> `deploy.yml` / `power.yml` pipeline is **GCP-bound and dead** (kept
> `workflow_dispatch`-only as a stub for when/if a cloud target is restored — do
> not rely on it). The only running environment is the **host-local Docker
> Compose stack** described below. There is **no separate staging vs prod** today;
> the single host-local stack *is* production. See memory
> `deploy-pipeline-dead-gcp-decommissioned` and issue #109.

**Supported runtime — host-local Docker Compose served by the Cloudflare tunnel:**
The full four-service stack runs as Docker Compose on a single host (currently a
WSL machine, ~31GB RAM) and is served on the production domains
(`chat`/`dify`/`evolution`/`middleware`/`grafana.nexaduo.com`) through the
**production Cloudflare tunnel** (`1eea65b4`, ingress → `coolify-proxy:80`). The
edge → tunnel → local-proxy → container path keeps the public URLs working with
no cloud spend.

Reproducible, code-driven bootstrap (no manual drift — issue #109):
1. **Inputs (operator-provided, host-local, NOT in git):**
   - `./.env` — the real production secrets (incl.
     `CHATWOOT_FRONTEND_URL=https://chat.nexaduo.com` and `TUNNEL_TOKEN`).
     Authoritative source is the pre-deletion export `generated.env`
     (OneDrive `gcp-export-2026-06-29/`), since Secret Manager is gone.
     Keys documented in [`.env.production.example`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.env.production.example).
     **This root `.env` is what the live stack loads — NOT `deploy/.env`**, which
     is a dev file with a `localhost:3000` `CHATWOOT_FRONTEND_URL` default
     (verified via #109; `run-stack.sh preflight` refuses a localhost value).
   - `$DUMPS_DIR` (`~/nexaduo-local/dumps`) — the `pg_dump` set to restore.
     Prefer the last-good `*-2026-06-25-0300.sql.gz` (see memory
     `prod-data-loss-2026-06-25`).
2. **Bootstrap:** [`scripts/run-stack.sh`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/run-stack.sh)
   `bootstrap` (= `preflight` + `up` + `restore`) brings up the whole stack +
   proxy + tunnel from the committed compose chain
   (`deploy/docker-compose.{shared,chatwoot,dify,nexaduo}.yml` + root
   `docker-compose.yml` + [`deploy/docker-compose.localproxy.yml`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/deploy/docker-compose.localproxy.yml)).
3. **Routing:** Traefik **Docker provider** reads the `traefik.*` router labels
   already committed on each service. The file-provider fallback (for hosts where
   the Docker provider is flaky, e.g. Docker Desktop/WSL) lives at
   [`deploy/traefik/dynamic.yml`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/deploy/traefik/dynamic.yml)
   and mirrors those labels 1:1.
4. **Validate:** `scripts/run-stack.sh validate` smoke-tests the real tunnel URLs
   and runs the Playwright connectivity + tenant-resolution suites against them.
5. **Backup:** [`scripts/backup-host.sh`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/backup-host.sh)
   (daily 03:00 host cron via `run-stack.sh install-cron`) replaces the dead
   GCS-bound `vm-backup.sh`.
6. **Host ports (optional isolation — issue #119):** by default the base compose
   publishes a few host ports for convenience/CI
   (chatwoot 3000, dify-web 3001, dify-api 5001, evolution 8080, middleware 4000,
   postgres 5432). Since the host is a shared Docker Desktop/WSL box, those can
   collide with other dev stacks. Run **`scripts/run-stack.sh --isolated up`**
   (or `ISOLATED=1`) to publish **zero** host ports: this appends
   [`deploy/docker-compose.isolated.yml`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/deploy/docker-compose.isolated.yml),
   which resets every `ports:` to empty via the Compose `!reset []` merge tag
   (needs Compose 2.24.4+; the host runs v5.x). Functionality is unchanged —
   public traffic still flows via the Cloudflare tunnel → Traefik, and
   service-to-service still uses the Docker network by container name (no service
   talks to another over `localhost`/`host.docker.internal`). When isolated,
   local debug access is via `docker exec` (e.g.
   `docker exec -it nexaduo-postgres-1 psql -U postgres`) — not `localhost:PORT`.
   The CI gate (`validate-stack`) keeps the base publishes and does **not** use
   this override.

**Legacy (GCP) model — retained for reference / future cloud restore only:**
1. **Foundation (Terraform):** GCP VM, VPC, Cloudflare Tunnel/DNS, Secrets in
   `infrastructure/terraform/envs/production/foundation`. The Cloudflare-only
   resources (tunnel/DNS) survive GCP loss; the GCP resources do not apply.
2. **App Layer (Bash/Docker):** `scripts/deploy-tenant-direct.sh` SCP/SSH'd
   configs to the VM. The `deploy.yml` pipeline orchestrated this. Dead until a
   cloud target exists again.

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
- **Backup (host-local runtime):** daily `pg_dump` (all DBs, `--clean
  --if-exists`) via [`scripts/backup-host.sh`](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/backup-host.sh)
  (host cron 03:00, installed by `run-stack.sh install-cron`). Dumps land in
  `~/nexaduo-local/dumps` and, if `BACKUP_RCLONE_REMOTE` is set, are copied
  **off-host** via rclone (a dump that only lives on the same host is not a
  backup). The script verifies critical DBs (`chatwoot`, `middleware`) were
  dumped and **fails** otherwise. `/dify-apps` backed up via Git.
  - This **replaces** the GCS/`gcloud`-bound `scripts/vm-backup.sh`, which is
    **dead** since GCP was decommissioned (`b02aa74`). `vm-backup.sh` is kept
    only for a future cloud restore.
  - **`pg_dump` is NOT a full backup.** Critical state lives in Docker volumes
    that no dump captures: Dify per-workspace RSA privkeys (encrypt the Azure
    OpenAI model-provider creds → lost = `PrivkeyNotFoundError` 500s) and
    chatwoot-storage uploads. Periodically archive the Docker volumes too. See
    memory `local-run-stack`.
- **Postgres data is SACRED.** On the host-local runtime it lives in the Docker
  named volume `nexaduo_postgres-data`. **Never** `docker compose down -v` or
  prune it; `run-stack.sh down` deliberately omits `-v`. The host serves
  production and is shared with concurrent work — do **not** recreate the
  postgres container casually. (Legacy GCP: it was a dedicated
  `google_compute_disk` guarded by `prevent_destroy` + daily snapshots; on
  2026-06-25 a `pd-balanced` `type` change recreated that disk **blank** and
  wiped production Chatwoot — never change a force-new disk attribute. See
  memory `prod-data-loss-2026-06-25`.)
- **Observability:** Grafana + Prometheus for queue depths and **token usage per account_id**.
- **Rate limiting:** Respect Meta tiers; throttle in Dify.

### Disaster recovery — restore Postgres from a dump (host-local runtime)

Dumps live in `~/nexaduo-local/dumps/<db>-<YYYY-MM-DD>-HHMM.sql.gz` (and, if an
off-host `BACKUP_RCLONE_REMOTE` is configured, a mirror there). The pre-deletion
full history is on OneDrive (`gcp-export-2026-06-29/dumps-full-history/`). The
last-good production set is `*-2026-06-25-0300.sql.gz` (see memory
`prod-data-loss-2026-06-25`). `scripts/run-stack.sh restore` automates the loop
below; to restore one DB (example: `chatwoot`) by hand onto the running stack:

1. **Archive current data first** (rollback): copy off the `nexaduo_postgres-data`
   volume, or take a fresh `backup-host.sh` dump before overwriting.
2. Pick the right dump — verify it has the data (`zcat <dump> | grep <marker>`);
   a post-incident dump may be of an already-empty DB.
3. Stop the consumers: `docker stop` the `nexaduo-chatwoot-*` containers (or the
   service that owns the DB).
4. Recreate the DB empty: terminate connections, `DROP DATABASE` + `CREATE
   DATABASE` (the dump is `--clean --if-exists`, so restoring onto a populated DB
   also works, but an empty DB is cleanest).
5. Restore: `zcat <dump> | docker exec -i nexaduo-postgres-1 psql -U postgres -d <db>`.
6. Start the consumers and validate row counts + the app responding via the
   tunnel (`scripts/run-stack.sh validate`).
7. **Remember the Docker volumes** (Dify privkeys, chatwoot-storage) — a dump
   restore alone leaves `PrivkeyNotFoundError`; restore the archived volumes or
   re-run `flask reset-encrypt-key-pair` and re-enter the Azure OpenAI creds.

(Legacy GCP path: dumps were at `gs://nexaduo-coolify-backups/...`, restored via
`gsutil cat | zcat | docker exec psql` after a `gcloud compute snapshots create`.
Dead with GCP.)

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

> **Realidade pós-GCP (issue #109):** não existe mais pipeline de deploy
> staging→prod por GitHub Actions, nem ambiente staging separado. Há **um único
> ambiente**: o stack host-local servido pelo túnel Cloudflare, que **é** a
> produção (ver "Deployment Strategy"). As fases abaixo foram reescritas para
> esse modelo de ambiente único. Toda mudança serializa nesse stack vivo — não
> recrie containers compartilhados (especialmente `nexaduo-postgres-1`) e
> coordene com qualquer trabalho concorrente no mesmo host.

- **Gate de CI (obrigatório, roda em todo PR):** o workflow
  `stack-compose-playwright.yml` (job `validate-stack`) sobe a stack inteira em
  efêmero no runner e roda Playwright (Stage 1 conectividade + Stage 4 resolução
  de tenant). É o portão real de merge — monitore-o até verde com `gh run watch`.
- **Fases Obrigatórias no Plano (ambiente único):**
  1. **CI verde** no PR (`validate-stack`).
  2. **Aplicar a mudança no stack vivo** a partir do código já mergeado
     (`scripts/run-stack.sh up`, ou recreate só do serviço afetado — nunca
     `down -v`, nunca o postgres sem necessidade).
  3. **Validação no ambiente real:** `scripts/run-stack.sh validate` — smoke das
     URLs reais do túnel + Playwright (`tests/01-infra.spec.ts`,
     `tests/07-hybrid-tenants.spec.ts`) apontando para `https://*.nexaduo.com`.
  4. **Confirmar saúde:** `scripts/health-check-all.sh` + inspeção dos
     containers `nexaduo-*` afetados (logs/printenv) para o caminho específico
     da correção.
  - Se uma fase genuinamente não puder rodar (ex.: ainda não há alvo de cloud
    para um deploy staging separado), **diga isso explicitamente** no PR — não
    finja uma fase que não existe.
- **Monitoramento Ativo de Workflows:** O agente não deve considerar a tarefa
  concluída apenas ao abrir o PR ou fazer o push. Deve monitorar o
  `validate-stack` no GitHub Actions (via `gh run watch`/logs) até verde, e
  então executar/observar a aplicação e a validação no stack vivo.
- **Validação com URLs Reais:** A validação no ambiente real deve rodar os testes
  automatizados (Playwright) apontando para as URLs reais do túnel
  (`https://*.nexaduo.com`) via `scripts/run-stack.sh validate`, e nunca apenas
  localmente.
- **Testes de Regressão no Playwright (Obrigatoriedade para Bugs):** Sempre que um bug for corrigido, o agente deve obrigatoriamente avaliar se faz sentido adicionar um teste de regressão ou asserção no Playwright para evitar que o erro ocorra novamente.
  - **Quando faz sentido:** Bugs de autenticação (ex: sessões expiradas, cookie security, redirecionamentos de login), problemas de roteamento (ex: redirecionamentos infinitos com SSL, links quebrados na interface), falhas em APIs consumidas pela UI (ex: erros 401, 500 no refresh de token ou rotas do console), validações de campos de formulário e fluxos de usuário ponta-a-ponta (E2E) que podem ser simulados via navegador.
  - **Quando não faz sentido:** Bugs de infraestrutura interna ou lógica que não são expostos/detectados no fluxo de usuário da web, tais como otimização de consultas SQL internas que não afetam respostas HTTP de maneira observável, configurações internas do sistema operacional, lógica interna do banco de dados que já é coberta por testes unitários, ou scripts auxiliares rodados sob demanda via CLI. Se o agente decidir que não faz sentido criar um teste no Playwright, ele deve justificar essa decisão na descrição da alteração ou em sua mensagem final.
  - **Como implementar:**
    - Crie ou edite arquivos dentro do diretório `onboarding/tests/` (ex: crie um novo arquivo `onboarding/tests/XX-nome-do-bug.spec.ts` ou adicione asserções no arquivo relevante como `03-smoke.spec.ts` ou `05-console-network.spec.ts`).
    - Capture falhas de rede usando interceptores de resposta do Playwright (`page.on('response', ...)` ou `page.waitForResponse(...)`).
    - Adicione comentários no código do teste explicando qual bug a asserção está prevenindo.
  - **Validação:** Antes de concluir a correção de um bug, o agente deve obrigatoriamente rodar os testes localmente (`npm run test:all` dentro da pasta `onboarding`) e garantir que a nova asserção/teste de regressão passe, além de monitorar o workflow no CI.


## Runbook: Instagram `external_error 100 — "não é a dona do tópico"` (subcode 2534037)

Cluster recorrente de relatórios do self-healing (issue **#64**, agrega #67, #69,
#72, #84, #97, #98, #100–#106). Mensagens **outgoing** em inboxes
`Channel::Instagram` ficam `status: failed` com
`100 - A ação é inválida porque não é a dona do tópico` (subcode `2534037`).

- **Não é bug do nosso stack.** O envio é 100% upstream do Chatwoot:
  `message.send_reply` → `SendReplyJob` → `Instagram::SendOnInstagramService` →
  `POST https://graph.instagram.com/v22.0/<instagram_id>/messages`. O nosso
  `middleware/` **não está no caminho da falha** (a mensagem que falha é a
  resposta do agente humano/da API, não um echo sem ator) e a nossa IaC só
  fornece as credenciais do app (`INSTAGRAM_APP_ID/SECRET/VERIFY_TOKEN` em
  `tenant/main.tf`). O `performed_by: nil` no `ActionCableBroadcastJob` é só o
  broadcast do status da mensagem já marcada `failed` — sintoma, não causa.
- **Diagnóstico confirmado empiricamente** (issue #64): com o token de produção,
  `GET /me` confirma o dono do canal, `GET /<ig_id>/conversations` mostra que a
  conta **possui** a thread, e os `participants` da thread batem exatamente com o
  `recipient.id` que o Chatwoot usa — ou seja, **endereçamento, ownership, token
  e janela de 24h estão todos corretos** e mesmo assim o **POST de envio** é
  rejeitado, enquanto o `GET` de perfil do mesmo id funciona. Leitura OK + envio
  bloqueado = **gating de permissão/modo do App Meta**, não dado.
- **Causa raiz:** o App Meta não tem **Advanced Access** para
  `instagram_business_manage_messages` (ou está em modo Development). Em
  Development o IG só envia para usuários com papel no app.
- **Correção (Meta App Dashboard — não versionável neste repo):** App Review →
  Advanced Access para `instagram_business_manage_messages`; mover o app para
  modo **Live**; reconectar o canal (re-OAuth) para o token carregar os escopos;
  validar reenviando e conferindo `messages.status = sent` + ausência de
  `external_error 100` em `nexaduo-chatwoot-sidekiq-1`.
- **Regressão Playwright N/A:** a falha é no job assíncrono Sidekiq; o `POST` da
  UI retorna 200 (mensagem criada) e só depois vira `failed` — não é observável
  como erro HTTP no fluxo web, e não há conexão Instagram controlável em CI.
  Verificação por API/DB/logs.

## Lições Aprendidas: Migrações de Banco de Dados em Ambientes Existentes

- **Convergência de Esquema é Automática (em código):** `01-init.sql` só roda na
  primeira inicialização do Postgres (volume vazio), então ambientes existentes
  nunca recebiam tabelas/colunas novas adicionadas a ele depois — foi exatamente
  o que quebrou o seed de `users`/`sessions` do admin portal. **Resolvido em
  código:** o job `sync` do `deploy.yml` agora reaplica `infrastructure/postgres/01-init.sql`
  no Postgres em execução em **todo deploy** (passo "Apply DB schema on VM"),
  antes do seed. O script é totalmente idempotente (`CREATE DATABASE ... \gexec`,
  `CREATE TABLE/INDEX/EXTENSION IF NOT EXISTS`), então qualquer ambiente converge
  para o esquema versionado sem intervenção manual.
- **Regra:** Para mudar o esquema do middleware/self_healing, **edite apenas
  `01-init.sql`** (mantendo tudo idempotente). O deploy aplica a mudança em
  novos e existentes ambientes automaticamente. Não há migração manual.
- **Break-glass (apenas emergência, fora do deploy):** se precisar aplicar à mão,
  use o mesmo caminho do pipeline e **depois** garanta que a mudança esteja em
  `01-init.sql`:
  1. `gcloud compute ssh <vm>` (via IAP).
  2. `PG=$(sudo docker ps --filter name=^/postgres- --format "{{.Names}}" | head -1)`
  3. `sudo docker exec -i "$PG" psql -U postgres -v ON_ERROR_STOP=1 < infrastructure/postgres/01-init.sql`




## Lição: falhas silenciosas de infra e "documentado ≠ rodando" (retro 2026-07-01)

Numa única sessão descobrimos três coisas de infra **quebradas em silêncio** que o
AGENTS.md descrevia como funcionando: (1) o cron de backup do Postgres apontava para
um script renomeado (`backup-local.sh` → `backup-host.sh`) e falhava há dias sem
alerta; (2) o file-provider do Traefik só existia como drift manual (perdido no
restart do WSL → 502); (3) o grafana caído por colisão de porta com outro stack no
host compartilhado. Lições duráveis:

- **Verificação é ativa, não confiança na doc.** Antes de dar algo por certo,
  confirme a realidade viva: `crontab -l`, `docker ps`, mtime do último dump, probe
  HTTP real. "Está no AGENTS.md" não é evidência de que está rodando.
- **Todo agendamento precisa de detecção de falha silenciosa.** Backup/job que pode
  falhar calado exige marcador de sucesso + check de staleness que **falha** um
  health-check quando o artefato mais novo passa do limite (ex.: dump ≥ 26h). Ver
  `scripts/backup-host.sh` (marcador `.last-success`) + `scripts/health-check-all.sh`.
- **Verificar antes de agir.** Não construa correção/IaC sobre um fato inferido
  (dono de um ID, significado de um valor). Uma suposição errada custou uma
  migração inteira revertida (o `INSTAGRAM_APP_ID` que era o app próprio do tenant,
  não de terceiro — ver memória `instagram-wrong-app-root-cause`).
- **Nada de sucesso prematuro em fluxo assíncrono.** Confirme o estado terminal
  (status/log/job), não o passo de enfileiramento.
