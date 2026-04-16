# Phase 5: Core Service Deployment - Context

**Gathered:** 2026-04-16
**Status:** Ready for planning

<domain>
## Phase Boundary

Deploy e verificar o stack completo de aplicação (Chatwoot, Dify, Middleware/Evolution API, Observabilidade) em ambiente multi-tenant-pronto, usando Terraform para gerenciar os recursos Coolify de forma reproduzível e versionada.

Escopo: DEPLOY-01, DEPLOY-02, DEPLOY-03, DEPLOY-04.
Não inclui: automação de provisionamento de novos tenants (Phase 4), novas integrações de canal.

</domain>

<decisions>
## Implementation Decisions

### Estratégia de Deploy no Coolify

- **D-01:** Usar **Terraform via provider `SierraJC/coolify`** para gerenciar todos os recursos Coolify. Integrado ao IaC existente do projeto (não scripts ad-hoc nem Coolify UI manual).
- **D-02:** **Um stack Coolify por serviço** — Chatwoot, Dify e Middleware/Evolution API como stacks separados. Isolamento de ciclo de vida: reiniciar um serviço não afeta os outros.
- **D-03:** Secrets gerenciados via **Terraform variables + `terraform.tfvars`** — consistente com o padrão atual do projeto. `terraform.tfvars` nunca commitado (`.gitignore`).

### Escopo dos Planos Formais

- **D-04:** Planos cobrem **Terraform completo**: recursos Coolify para todos os serviços + rede interna Coolify + env vars injetadas via Terraform. Um plano por stack + um plano de verificação E2E.
- **D-05:** Cada plano de stack inclui validação de saúde pós-deploy (health check do serviço no Coolify ou endpoint de status).

### Referências de Compose Existentes

- Os arquivos `deploy/docker-compose.*.yml` já existem e são a fonte de verdade para a definição dos serviços. Os planos Terraform referenciam esses arquivos via recurso Coolify (Docker Compose source).
- `.env.example` é o template canônico de secrets — todo novo env var deve ser adicionado lá primeiro.

### Claude's Discretion

- Ordem exata dos recursos Terraform (depends_on entre stacks)
- Nome dos recursos Coolify e network interna
- Detalhes do health check por serviço (endpoint, intervalo)
- Estrutura de módulos Terraform para os recursos Coolify

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Compose Sources (definição dos serviços)
- `deploy/docker-compose.shared.yml` — Postgres 16 + pgvector, Redis 7 (serviços compartilhados)
- `deploy/docker-compose.chatwoot.yml` — Chatwoot app + Sidekiq workers
- `deploy/docker-compose.dify.yml` — Dify API, worker, web, sandbox
- `deploy/docker-compose.nexaduo.yml` — Middleware bridge + Evolution API

### Configuração
- `.env.example` — Template canônico de todas as variáveis de ambiente
- `infrastructure/postgres/01-init.sql` — Init dos 3 bancos lógicos (chatwoot, dify, evolution)

### IaC Existente
- `infrastructure/terraform/envs/production/` — Ambiente de produção atual (padrão de estrutura)
- `infrastructure/terraform/modules/` — Módulos reutilizáveis (referência de padrão)

### Roadmap e Requirements
- `.planning/ROADMAP.md` — Phase 5 success criteria
- `.planning/REQUIREMENTS.md` — DEPLOY-01 a DEPLOY-04 detalhados

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `deploy/docker-compose.*.yml`: Definições de serviço prontas — Terraform Coolify resource aponta para esses arquivos como fonte
- `observability/`: Configs de Grafana, Prometheus, Loki, OTEL e Promtail já existem — precisam ser integrados no stack de observabilidade do Coolify
- `infrastructure/terraform/envs/production/`: Padrão de estrutura de ambiente a replicar para os novos recursos Coolify

### Established Patterns
- Terraform com backend remoto no GCS (`nexaduo-terraform-state`)
- Variáveis em `terraform.tfvars` (não commitado), declaradas em `variables.tf`
- Módulos reutilizáveis em `infrastructure/terraform/modules/`

### Integration Points
- Novos recursos Terraform (Coolify stacks) entram em `infrastructure/terraform/envs/production/`
- Secrets do `.env.example` viram Terraform variables passadas aos recursos Coolify

</code_context>

<specifics>
## Specific Ideas

- O PoC já está rodando manualmente — os planos Terraform formalizam o estado atual, não reimplementam do zero
- Isolamento por stack no Coolify é crítico para operação: permite restart/update de Chatwoot sem derrubar Dify

</specifics>

<deferred>
## Deferred Ideas

- GCP Secret Manager para secrets (anotado na Phase 1 como deferred) — continua deferred
- Docker resource limits por container (anotado na Phase 1 como deferred para Phase 5, mas não discutido — fica a critério do planner)
- Configuração do Middleware bridge, escopo da Observabilidade e critérios de verificação E2E — áreas não discutidas nesta sessão, deixadas para o planner inferir dos requirements e codebase

</deferred>

---

*Phase: 05-core-service-deployment*
*Context gathered: 2026-04-16*
