# Phase 5: Core Service Deployment - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-04-16
**Phase:** 05-core-service-deployment
**Areas discussed:** Formalização do deploy via Coolify

---

## Formalização do deploy via Coolify

| Option | Description | Selected |
|--------|-------------|----------|
| Terraform via provider SierraJC/coolify | IaC reproduzível, versionado, integrado ao projeto | ✓ |
| Coolify UI + documentação dos passos | Manual, mais simples mas propenso a derivação | |
| Scripts via Coolify API | Automação sem Terraform, menos integrado | |

**User's choice:** Terraform via provider SierraJC/coolify

---

| Option | Description | Selected |
|--------|-------------|----------|
| Um stack do Coolify por serviço | Isolamento de ciclo de vida por serviço | ✓ |
| Um stack unificado com compose files modulares | Simples, mas atualiza tudo junto | |
| Você decide | Deixar para o planner | |

**User's choice:** Um stack do Coolify por serviço (Chatwoot, Dify, Middleware separados)

---

| Option | Description | Selected |
|--------|-------------|----------|
| Terraform variables + terraform.tfvars | Padrão atual do projeto | ✓ |
| Coolify UI para secrets | Separação limpa, mas fora do IaC | |
| GCP Secret Manager | Mais seguro, mais complexo (deferred Phase 1) | |

**User's choice:** Terraform variables + terraform.tfvars

---

| Option | Description | Selected |
|--------|-------------|----------|
| Terraform completo: todos os serviços + rede + env vars | Planos abrangentes, um por stack | ✓ |
| Só o que falta do PoC | Foco nas lacunas do manual | |
| Documentação retroativa + E2E | Captura estado atual + testes | |

**User's choice:** Terraform completo: todos os serviços + rede Coolify + env vars

---

## Claude's Discretion

- Ordem dos recursos Terraform (depends_on)
- Nomes dos recursos e rede interna no Coolify
- Detalhes de health check por serviço
- Estrutura de módulos Terraform para Coolify
- Configuração do Middleware, Observabilidade, verificação E2E (não discutidas — planner infere dos requirements)

## Deferred Ideas

- GCP Secret Manager (continuação do deferred da Phase 1)
- Docker resource limits por container (deferred da Phase 1)
