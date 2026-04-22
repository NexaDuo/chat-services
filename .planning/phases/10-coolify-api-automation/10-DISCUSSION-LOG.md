# Phase 10: Coolify API Automation — Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-22
**Phase:** 10-coolify-api-automation
**Outcome:** DEFERRED (see `10-CONTEXT.md` for rationale + trigger conditions)
**Areas discussed:** Implementation approach → Strategic direction → Phase scope

---

## Round 1 — Implementation-level gray areas (presented)

Apresentadas 4 gray areas assumindo Option A (manter provider `SierraJC/coolify`, migrar para `coolify_service_envs`):

| Option | Description | Selected |
|--------|-------------|----------|
| Race `instant_deploy` vs envs | Pitfall 6 do research: instant_deploy=false + null_resource pós-apply OU instant_deploy=true + aceitar cold-start crash-loop | |
| Ordem de migração de stacks | shared→chatwoot→dify→nexaduo sequencial vs all-at-once | |
| `FORCE_REDEPLOY_HASH` + trigger de redeploy | Remover hash + null_resource OR manter para topology changes OR usar terraform apply -replace | |
| Escopo do `bootstrap-coolify.sh` | Estender para criar destination idempotentemente OR manter manual | |

**User response:** *"será que abandonar o provider terraform e adotar uma nova estratégia não é uma opção melhor e mais simples no longo prazo?"*

User rejeitou o framing implementation-level e forçou re-framing estratégico.

---

## Round 2 — Strategic direction

Apresentada análise comparativa de 4 estratégias (A: manter provider / B: abandonar e reconciler / C: abandonar Coolify / D: híbrido).

| Option | Description | Selected |
|--------|-------------|----------|
| A. Manter provider Terraform | Segue plano da pesquisa, ~85% declarativo, accepted gaps | |
| B. Abandonar provider, reconciler próprio | Reconciler TS chama Coolify REST direto, ~95%+ declarativo | |
| D. Híbrido: TF infra + reconciler Coolify | Terraform só para GCP/Cloudflare + reconciler TS para layer Coolify | ✓ (inicial) |
| Outra direção / quero discutir mais | Escape hatch para alternativa fora da tabela | |

**User's choice (Round 2):** D. Híbrido — reconciler próprio para o layer Coolify.

---

## Round 3 — Reconciler shape gray areas (presented mas não respondidas)

Apresentadas 4 gray areas para o reconciler Option D:
- Formato e localização do manifest
- Estratégia de cutover do Terraform tenant layer
- State / drift detection (stateless vs state file vs Secret Manager)
- Fronteira bootstrap-coolify.sh vs reconciler (destination/project ownership)

**User response:** *"será que precisamos da definição do coolify ascode mesmo? ou um setup inicial asumindo novas changes pelaa UI já resolve?"*

User questionou o premise pela segunda vez — agora se Coolify-as-code valia o esforço. Requisitou análise de value-vs-effort.

---

## Round 4 — Phase scope (análise conduzida)

Apresentada matriz de 4 drivers (multi-tenant programmatic, multi-env parity, DR speed, compliance, rotation cadence) versus 4 opções de escopo.

| Option | Description | Selected |
|--------|-------------|----------|
| 2. Lean: UI-managed + runbook | Runbook formal + script rotação de envs + DR test. Fecha v1.1 pragmaticamente | |
| 4. Envs-only reconciler | Reconciler mini só para rotação de envs, topology continua UI | |
| 3. Deferir INFRA-06 v1.1 | Remover/postergar Phase 10, revisitar quando driver concreto materializar | ✓ |
| 1. Reconciler full (plano D anterior) | Seguir com reconciler completo | |

**User's choice (Round 4 / final):** 3. Deferir INFRA-06 v1.1 — remover/postergar Phase 10, reabrir quando driver concreto aparecer.

---

## Claude's Discretion

Nenhuma — todas as decisões foram strategic choices do usuário. O valor deste discuss foi justamente filtrar um premise que poderia ter virado 2 semanas de implementação sem ROI concreto.

---

## Deferred Ideas

Todas as 4 gray areas do Round 1 (instant_deploy race, migration order, FORCE_REDEPLOY_HASH, bootstrap scope) e todas as 4 gray areas do Round 3 (manifest format, cutover strategy, state tracking, bootstrap boundary) ficam deferidas. Reabrir junto com INFRA-06 v1.1 quando uma trigger condition de `D-10-101` for disparada.

A pesquisa técnica (`10-RESEARCH.md`) permanece plan-ready — não precisa ser refeita.
