# Plano de Hospedagem — NexaDuo Chat Services

## Objetivo
Definir uma estratégia de hospedagem **mais barata possível** (região US), com **infra 100% via código** (Terraform), atualização simples via Docker Compose e suporte a multi-tenant com **Cloudflare** roteando URLs do tipo `https://chat.nexaduo.com/{tenant_id}/app` para o Chatwoot.

## Estado atual (repo)
- Stack pronta via **docker-compose** com Chatwoot, Evolution API, Dify, Middleware, Postgres+pgvector e Redis.
- Observabilidade (Prometheus/Grafana) já provisionada.
- Backup via `scripts/backup.sh`.
- Proxy externo esperado (Coolify/Traefik) — sem nginx interno.

## Premissas
- Região de referência: **US** (comparativo de menor custo).
- **Janela de manutenção curta** aceita para atualizações (sem zero-downtime).
- Infra declarada em **Terraform**.
- Cloudflare pode ser usado para **rotear por tenant**.
- Provedor principal recomendado: **GCP** (menor custo estimado no comparativo).

## Comparativo de custo (VM 4 vCPU / 16 GB RAM, on-demand, Linux, US)
> Fonte: dataset público do ec2instances.info (Vantage) e equivalentes para GCP/Azure. Valores aproximados, sem disco e egress.

| Provedor | Tipo de VM (equivalente) | Região | $/hora | $/mês (730h) | Observações |
|---|---|---|---:|---:|---|
| **GCP** | e2-standard-4 | us-central1 | **0.1340** | **97.84** | Mais barato para 4vCPU/16GB |
| **Azure** | D4as v5 (linux-d4asv5-standard) | us-east | **0.1720** | **125.56** | Próximo do AWS, mais caro que GCP |
| **AWS** | m6i.xlarge | us-east-1 | **0.1920** | **140.16** | Custo maior |

> **Conclusão:** GCP é a escolha de menor custo para o perfil mínimo recomendado (4 vCPU / 16 GB). Azure é alternativa viável; AWS é o mais caro no mesmo perfil.

## Arquitetura de hospedagem (baseline barato)
**Estratégia:** 1 VM única (single-node) com Docker Compose.

- **VM**: 4 vCPU / 16 GB RAM / SSD 50–100 GB
- **SO**: Ubuntu 24.04 LTS
- **Rede**: 1 IP público + firewall básico (SSH restrito)
- **Proxy**: Traefik/Coolify no host (ou Cloudflare Tunnel)
- **Backup**: cron diário rodando `scripts/backup.sh` + upload para storage barato (GCS/Backblaze/S3)

## Racional de Decisão: Coolify
A escolha do Coolify como orquestrador baseia-se nos seguintes pontos:
- **Experiência PaaS (Heroku/Vercel) "Self-Hosted":** Oferece interface visual para gestão de containers, variáveis de ambiente e SSL (Let's Encrypt) sem o custo de serviços gerenciados.
- **Paridade Local/Cloud:** O Coolify é open-source e idêntico em qualquer ambiente. É possível rodar a mesma versão localmente (via Docker) para testes idênticos ao ambiente de produção.
- **Eficiência de Recursos (Docker vs Kubernetes):** O Coolify opera sobre **Docker Engine/Swarm**. Ao contrário do Kubernetes, que possui um "control plane" pesado, o Docker permite que quase 100% dos 16GB de RAM da VM sejam dedicados às aplicações (Dify, Chatwoot, etc.).
- **Escalabilidade Manual vs Automática:** Para manter o custo baixo, aceita-se a limitação de **não possuir auto-scaling nativo** (infra elástica). O escalonamento é feito via verticalização da VM ou aumento manual de réplicas no painel, o que atende ao perfil de custo do projeto.

## Atualizações das aplicações
**Fluxo simples (manutenção curta):**
1. `git pull` no host
2. `docker compose pull` (imagens oficiais)
3. `docker compose up -d`
4. Verificação rápida (`docker compose ps`, healthchecks)

**Política de update:**
- Atualizar **mensalmente** (ou em releases críticos)
- Versionamento fixo em `docker-compose.yml`
- Validar tags antes do deploy

## Multitenancy via Cloudflare
**Objetivo:** `https://chat.nexaduo.com/{tenant_id}/app` → Chatwoot.

Opções:
1. **Cloudflare Workers**: reescrever URL e adicionar header `X-Tenant-Id` para o middleware (ou para o Chatwoot via proxy).
2. **Cloudflare Rules**: reescrita simples de path para `/app` no Chatwoot.

Recomendado:
- Worker simples que:
  - extrai `{tenant_id}` do path
  - reescreve para `/app`
  - injeta header `x-tenant-id` (futuro uso no middleware)

## Infra via código (Terraform)
**MVP GCP:**
- `google_compute_instance` (VM)
- `google_compute_firewall` (SSH + portas 80/443)
- `google_compute_address` (IP estático)
- `google_compute_disk` (SSD)
- `cloudflare_record` (DNS)

**Estrutura sugerida:**
```
/infrastructure/terraform
  /modules
    /gcp-vm
    /cloudflare-dns
  /envs
    /prod
```

## Plano de implementação (GCP)
- [ ] Criar módulo Terraform GCP (VM + rede + disco + firewall)
- [ ] Criar módulo Cloudflare DNS (A/AAAA + proxied)
- [ ] Definir variáveis: domínio, zona, tamanho de VM, região, SSH key
- [ ] Provisionar VM e validar SSH
- [ ] Instalar Docker + Docker Compose no host
- [ ] Deploy inicial: `docker compose up -d`
- [ ] Configurar backups (cron + upload)
- [ ] Configurar Cloudflare Worker (roteamento por tenant)
- [ ] Documentar rotina de update

### Plano de implementação no repo (Coolify local)
**Problema:** Implementar no repo o plano de hospedagem (GCP + Cloudflare + Coolify) com infra via Terraform, Worker para multi-tenant e orientações de uso com Coolify local.

**Abordagem:**
- Criar estrutura Terraform em `/infrastructure/terraform` com módulos reutilizáveis (gcp-vm, cloudflare-dns, cloudflare-worker) e ambiente `/envs/prod`.
- Incluir script do Worker (rewrite + header `x-tenant-id`).
- Atualizar este documento com instruções objetivas de uso com Coolify local e referência aos caminhos Terraform.
- Validar se há testes/linters existentes nos pacotes JS e rodar quando aplicável.

**Workplan (execução no repo):**
- [ ] Levantar scripts/testes existentes nos pacotes
- [ ] Criar estrutura Terraform (providers, módulos, envs/prod)
- [ ] Implementar Cloudflare Worker (script + recurso terraform)
- [ ] Atualizar docs/plans/hosting.plan.md (Coolify local + como aplicar Terraform)
- [ ] Rodar verificações disponíveis
- [ ] Resumir mudanças

**Notas/assunções:**
- GCP como provedor padrão, VM única 4 vCPU/16GB.
- Cloudflare Worker faz rewrite para `/app` e injeta header `x-tenant-id`.
- Coolify local usado apenas para paridade de deploy (sem executar aqui).

## Notas
- Se for necessário **zero-downtime**, migrar para 2 VMs + proxy L7 (custo maior).
- Para crescimento: separar banco (Postgres) em VM dedicada ou gerenciado.

---
**Arquivo criado em:** `docs/plans/hosting.plan.md`
