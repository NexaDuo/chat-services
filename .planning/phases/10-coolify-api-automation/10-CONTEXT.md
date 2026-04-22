# Phase 10: Coolify API Automation — Context (DEFERRED)

**Gathered:** 2026-04-22
**Status:** ⛔ DEFERRED — phase will not proceed as originally scoped

<domain>
## Phase Boundary (original intent)

Entregar INFRA-06 v1.1 — "100% declarative Coolify service provisioning". A intenção original era migrar o layer `infrastructure/terraform/envs/production/tenant/` de `coolify_service` + secrets inline via `templatefile()` para um modelo plenamente declarativo, eliminando steps manuais na UI do Coolify.

## Outcome

Após discuss-phase, o escopo original foi **deferido**. Phase 10 não shipa como descrita no ROADMAP e deve sair do roadmap ativo (ou ser renomeada para refletir o resultado). Full IaC para Coolify (reconciler TypeScript ou refactor do provider) fica adiado até surgir um driver concreto.

</domain>

<decisions>
## Implementation Decisions

### Strategic Pivot
- **D-10-99:** Phase 10 como originalmente planejada (INFRA-06 v1.1 — "100% declarative Coolify service provisioning") é **DEFERIDA**. Nenhum reconciler é construído; o provider `SierraJC/coolify` v0.10.2 permanece como está em `infrastructure/terraform/envs/production/tenant/`; nenhum refactor para `coolify_service_envs`; gerenciamento via UI Coolify + secrets rotacionados via runbook continuam sendo o modelo operacional.

### Rationale
- **D-10-100:** Automação declarativa plena é otimização prematura para o estado atual do projeto. Stack tem 4 services estáticos, único ambiente (produção), sem demanda iminente de multi-tenant fan-out ou staging. UI do Coolify + `deploy/docker-compose.*.yml` em Git + GCP Secret Manager + runbook de rotação já cobrem ~90% da necessidade operacional real. Construir reconciler custaria ~2 semanas para resolver uma dor que ainda não existe.

### Trigger Conditions to Reopen
- **D-10-101:** Reabrir INFRA-06 v1.1 quando QUALQUER uma destas condições materializar:
  1. **PROV-04** (multi-tenant one-click onboarding) entra em planejamento ativo — provisionamento programático de tenant exige criação IaC-driven de resources Coolify.
  2. Ambiente de staging ou pre-prod é adicionado ao projeto — paridade de ambiente exige service config reprodutível.
  3. Cadência de rotação manual de segredos excede mensal E vira dor operacional (medida: updates em 4 services consumindo >2h/mês).
  4. SLO de DR apertar para <30min — runbook manual para rebuild do Coolify fica lento demais.
  5. Requisito regulatório/audit exige mudanças de infra revisadas via PR (hoje é OK via UI).

### Claude's Discretion
- Nenhuma — isto é decisão de escopo, não de implementação.

### Folded Todos
- Nenhum todo pendente se encaixa nesta fase (cross-reference retornou 0 matches).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents que eventualmente reabrirem esta fase DEVEM ler estes arquivos primeiro.**

### Decision inputs (ainda autoritativos para futuro reopen)
- `.planning/phases/10-coolify-api-automation/10-RESEARCH.md` — Análise completa do provider `SierraJC/coolify` v0.10.2, accepted gaps, layered declaration pattern, 4-plan decomposition proposto. Permanece válido como baseline técnico se a direção de reconciler for revisitada.
- `infrastructure/terraform/envs/production/tenant/main.tf:1-173` — Pattern atual: 4x `coolify_service` com `templatefile()` injetando ~14 secrets. Intocado por esta fase; será o "before" de uma futura migração.
- `infrastructure/terraform/envs/production/tenant/providers.tf:1-26` — Pinning do provider `SierraJC/coolify` v0.10.2; inalterado.

### Milestone/requirement impact (precisa update após a deferral)
- `.planning/MILESTONES.md` v1.1 § Key Goals — o bullet "Full Coolify API Automation (INFRA-06)" precisa ser alterado para marcar deferral + trigger conditions.
- `.planning/REQUIREMENTS.md` § Traceability — linha INFRA-06 deve mudar de `Phase 10 | Pending` para `Backlog | Deferred` com link para trigger conditions.

### Baseline operacional preservado
- `.planning/phases/09-architectural-infrastructure-refactor/09-CONTEXT.md` — Arquitetura 3-step (Foundation → Bootstrap → Applications) permanece operacional. Deferral não afeta Phase 09.
- `deploy/docker-compose.*.yml` — Topologia dos 4 stacks permanece como está; já é Git-versionada.
- `scripts/bootstrap-coolify.sh` — Continua com papel one-time (install Coolify + gerar API token); não é estendido.

</canonical_refs>

<code_context>
## Existing Code Insights

### State unchanged by this phase
- `infrastructure/terraform/envs/production/tenant/main.tf` — 4 resources `coolify_service` (shared, chatwoot, dify, nexaduo) continuam com secret interpolation via `templatefile()`. Não refatorado.
- `infrastructure/terraform/envs/production/tenant/secrets.tf` — data sources de `google_secret_manager_secret_version` continuam sendo o canal de injeção de segredos para o compose template.
- `scripts/bootstrap-coolify.sh` — papel one-time (install + token) preservado. Nenhuma extensão para destination creation (segue assumindo destination manual via UI).
- `deploy/docker-compose.*.yml` (4 arquivos) — já Git-versionados; continuam como source of truth de topologia.

### Established patterns (valem como baseline futuro)
- `templatefile()` + `data.google_secret_manager_secret_version` é o padrão atual de injeção de segredos no compose. Quando reconciler for implementado, este será o pattern a substituir.
- `lifecycle.ignore_changes` para `server_uuid`, `project_uuid`, `destination_uuid`, `environment_name` em todos os 4 services — compensa drift da UI em campos imutáveis. Padrão preservado.
- `depends_on` entre services (chatwoot/dify/nexaduo → shared, nexaduo → chatwoot+dify) — ordenação stack-a-stack funciona no provider; preservada.

### Integration points
- **Phase 09 deployment**: 3-step Foundation → Bootstrap → Applications. Phase 10 deferral significa que Step 3 continua sendo `terraform apply` no tenant layer usando provider `SierraJC/coolify`.
- **Phase 06 Secret Manager**: GCP Secret Manager continua SSoT. Nenhuma mudança nesta fronteira.

</code_context>

<specifics>
## Specific Ideas

### Reframings do usuário durante o discuss
1. Primeira pergunta: *"será que abandonar o provider terraform e adotar uma nova estratégia não é uma opção melhor e mais simples no longo prazo?"* — levou à análise comparativa Provider vs Reconciler vs Hybrid (Option D eleita inicialmente).
2. Segunda pergunta: *"será que precisamos da definição do coolify ascode mesmo? ou um setup inicial asumindo novas changes pelaa UI já resolve?"* — levou a reconsiderar o premise de INFRA-06 v1.1 inteira, resultando na deferral.

### Leitura operacional consolidada
- Custo operacional real de UI-managed é baixo dado o shape atual do stack (4 services, único ambiente, poucos tenants).
- A claim de "100% declarativo" era goal aspiracional sem driver de negócio concreto; abandonamos o goal em si, não apenas a abordagem.
- Topology (compose) já está versionada; o que ficou "manual" (destination, project, services wiring, envs individuais) é baixa frequência de mudança e aceitável via UI + runbook.

</specifics>

<deferred>
## Deferred Ideas

### Full reconciler (Option D originalmente escolhida)
Quando uma trigger condition disparar, reabrir com o escopo explorado:
- TypeScript reconciler (`scripts/coolify-reconcile.ts` ou `packages/coolify-reconciler/`) consumindo um manifest declarativo e chamando Coolify REST API diretamente.
- Abandonar `SierraJC/coolify` provider no tenant layer; manter Terraform só para Foundation.
- Reconciler cuida de destination + project + services + envs + deploy-triggers.
- Cutover: import-first (reconciler adota UUIDs existentes via API query antes de deletar TF resources).

### Lean middle-ground (Option 2)
Se a dor for exclusivamente rotação de segredos em lote: shippar só `coolify-rotate-envs` (wrapper `gcloud secrets access` + `curl` à Coolify API) + runbook formal + DR test. Escopo ~3–5 dias.

### Envs-only reconciler (Option 4)
Escopo intermediário: reconciler TS MINI cuidando exclusivamente de env rotation. Topology/destination/project continuam via UI.

### Research file intact
O `10-RESEARCH.md` permanece como análise técnica completa e plan-ready — quando a fase reabrir, o researcher pode ser pulado.

### Reviewed Todos (not folded)
Nenhum — cross-reference de todos para Phase 10 retornou 0 matches.

</deferred>

---

*Phase: 10-coolify-api-automation*
*Context gathered: 2026-04-22*
*Outcome: **DEFERRED** — scope moved to backlog pending trigger conditions in D-10-101*
