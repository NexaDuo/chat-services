---
title: Separar camadas de Infraestrutura (Foundation) e Tenant (Applications)
status: done
area: infrastructure
priority: high
created_at: 2026-04-21
completed_at: 2026-04-22
completed_in: Phase 09 (architectural-infrastructure-refactor)
---

## Problema
O acoplamento atual no Terraform entre a criação da VM e a definição dos serviços no Coolify gera erros de "Connection Timeout" e "Invalid Provider Configuration". O Terraform tenta validar o provedor do Coolify antes da API estar disponível ou do token ser gerado.

## Plano de Ação
1. **Foundation Layer:** Criar um workspace Terraform isolado para GCP (VM, VPC, Firewall) e Cloudflare (Tunnel).
2. **Bootstrap Script:** Refinar o `bootstrap-coolify.sh` para ser o elo entre as fases, gerando o segredo no GCP Secret Manager.
3. **Tenant Layer:** Criar um workspace Terraform separado para as Stacks (Chatwoot, Dify, NexaDuo) que consome o Token gerado e depende da estabilidade da Fundação.
4. **Documentação:** Atualizar `ARCHITECTURE.md` para refletir a nova estrutura de 3 passos.

## Definição de Pronto
- [ ] Fundação sobe sem erros de provedor.
- [ ] Bootstrap gera token e salva no Secret Manager de forma confiável.
- [ ] Tenant consegue dar deploy nas stacks sem intervenção manual ou timeouts de API.
