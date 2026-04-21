<!-- generated-by: gsd-doc-writer -->
# chat-services — NexaDuo Omnichannel AI Stack

Stack de atendimento omnichannel **production-ready no dia zero**: Chatwoot como hub único, Evolution API para WhatsApp/Instagram, Dify como cérebro agêntico (RAG + MCP) e um middleware Node.js que fecha o loop Chatwoot ⇄ Dify.

> Blueprint completo em pt-BR: [`docs/plans/first-setup.plan.md`](docs/plans/first-setup.plan.md).
> Convenções para contribuir com IA: [`CLAUDE.md`](CLAUDE.md).

## URLs de Produção

A stack é orquestrada via Coolify e exposta nos seguintes domínios:

- **Coolify (Painel):** [coolify.nexaduo.com](https://coolify.nexaduo.com)
- **Chatwoot (Inbox/CRM):** [chat.nexaduo.com](https://chat.nexaduo.com)
- **Dify (IA/Agentes):** [dify.nexaduo.com](https://dify.nexaduo.com)

### Estratégia de Multi-tenancy (Futuro)
Para suporte a múltiplos tenants em uma stack compartilhada, o roteamento será baseado em paths:
- **Chatwoot:** `chat.nexaduo.com/{tenant}/`
- **Dify:** `dify.nexaduo.com/{tenant}/`

## Arquitetura

```
          ┌────────────┐       ┌────────────┐     ┌─────────────────────┐
WhatsApp ▶│ Evolution  │──────▶│  Chatwoot  │────▶│   Middleware (TS)   │
          │  API v2    │       │  (hub/CRM) │     │  /webhooks/chatwoot │
          └────────────┘       └────────────┘     └──────────┬──────────┘
                                     ▲                        │
                                     │  resposta do agente    │
                                     │                        ▼
                                     │               ┌─────────────────┐
                                     └───────────────│  Dify (agent +  │
                                                     │  RAG pgvector)  │
                                                     └────────┬────────┘
                                                              │
                                                              ▼
                                                    ┌──────────────────┐
                                                    │  Azure OpenAI    │
                                                    │  gpt-4o(-mini)   │
                                                    └──────────────────┘
```

Infra compartilhada: **um** Postgres 16 + `pgvector` (3 DBs: `chatwoot`, `dify`, `dify_plugin`, `evolution`) e **um** Redis 7 (DBs lógicos `0` = Dify, `1` = Chatwoot, `2` = Evolution).

## Quickstart

### 1. Segredos

```bash
cp .env.example .env

# Gere valores fortes (copie para dentro do .env):
openssl rand -hex 64    # CHATWOOT_SECRET_KEY_BASE, DIFY_SECRET_KEY
openssl rand -hex 32    # REDIS_PASSWORD, POSTGRES_PASSWORD,
                        # EVOLUTION_AUTHENTICATION_API_KEY,
                        # DIFY_SANDBOX_API_KEY, DIFY_PLUGIN_DAEMON_KEY,
                        # DIFY_PLUGIN_DIFY_INNER_API_KEY,
                        # HANDOFF_SHARED_SECRET
```

Preencha também `AZURE_OPENAI_*` e `CHATWOOT_FRONTEND_URL` / `DIFY_CONSOLE_WEB_URL` com as URLs públicas (`chat.nexaduo.com` e `dify.nexaduo.com`).

### 2. Validar o compose

```bash
docker compose config > /dev/null && echo "OK"
```

### 3. Subir a infra base + init do Chatwoot

```bash
docker compose up -d postgres redis
docker compose run --rm chatwoot-init    # roda rails db:chatwoot_prepare uma vez
```

### 4. Subir o resto do stack

```bash
docker compose up -d
docker compose ps    # todos os healthy em ~2 min (dify-api leva até 120s no start_period)
```

### 5. Primeiro login (manual, uma vez só)

| Serviço    | URL local              | URL Produção | O que fazer                                               |
| ---------- | ---------------------- | ------------ | --------------------------------------------------------- |
| Chatwoot   | `http://localhost:3000`  | `chat.nexaduo.com` | Crie o super-admin. Vá em *Profile → Access Token* e copie. |
| Dify       | `http://localhost:3001`  | `dify.nexaduo.com` | Wizard de setup. Configure **Azure OpenAI** em *Settings → Model Provider*. Crie um App (Chatflow/Agent) e copie a **Service API Key**. |
| Evolution  | `http://localhost:8080/manager` | — | Autentique com `EVOLUTION_AUTHENTICATION_API_KEY`. Crie uma instância WhatsApp (QR code). |
| Grafana    | `http://localhost:3002`  | — | Login `GRAFANA_ADMIN_*`. Dashboard "NexaDuo — Chat Services" já provisionado. |
| Prometheus | `http://localhost:9090`  | — | — |

### 6. Conectar middleware ao Chatwoot e ao Dify

Com os tokens copiados no passo anterior, edite `.env`:

```env
CHATWOOT_API_TOKEN=<token do admin Chatwoot>
TENANT_MAP={"1":{"dify_api_key":"app-XXXXXXXX"}}
```

```bash
docker compose up -d middleware
docker compose logs -f middleware    # espere "middleware: listening" + tenants=1
```

### 7. Registrar o webhook no Chatwoot

No Chatwoot: *Settings → Integrations → Webhooks → Add new webhook*

- URL: `http://middleware.local:4000/webhooks/chatwoot` (rede Docker) **ou** a URL pública do middleware
- Eventos: **Conversation Created**, **Message Created**

### 8. Teste end-to-end

Envie uma mensagem pelo WhatsApp conectado à instância do Evolution. A sequência esperada:

```
WhatsApp → Evolution → Chatwoot conversation (incoming)
        → webhook POST /webhooks/chatwoot
        → middleware → Dify /chat-messages (blocking)
        → resposta postada no Chatwoot via /messages (outgoing)
        → WhatsApp recebe a resposta
```

Checagens rápidas:

```bash
curl -s http://localhost:4000/health
curl -s http://localhost:4000/metrics | grep middleware_dify
```

## Handoff humano

O Dify chama o middleware via HTTP Tool (Dify Studio → *Tools → Custom → HTTP request*):

```http
POST http://middleware.local:4000/tools/handoff
x-handoff-secret: ${HANDOFF_SHARED_SECRET}
Content-Type: application/json

{
  "account_id": "{{chatwoot_account_id}}",
  "conversation_id": "{{chatwoot_conversation_id}}",
  "summary": "Cliente quer cancelar a assinatura..."
}
```

Efeito: a conversa vira `open`, recebe o label `atendimento-humano` e uma **private note** com o sumário do agente.

## Estrutura do repo

```
docker-compose.yml                 # Stack unificada (Postgres, Redis, Chatwoot, Evolution, Dify, Middleware, Prom/Grafana)
.env.example                       # Template de segredos
infrastructure/postgres/           # Init SQL (CREATE DATABASE + pgvector)
middleware/                        # Node 22 / Fastify / TypeScript — adapter Chatwoot ⇄ Dify
dify-apps/                         # YAML (DSL) exports dos agentes — versionados
provisioning/                      # Scripts de onboarding de tenants
scripts/                           # backup.sh (pg_dump diário)
observability/                     # prometheus.yml + dashboards Grafana provisionados
docs/plans/first-setup.plan.md     # Blueprint (pt-BR) — fonte arquitetural
```

## Versões pinadas

| Componente | Imagem |
| :--- | :--- |
| Postgres + pgvector | `pgvector/pgvector:pg16` |
| Redis | `redis:7-alpine` |
| Chatwoot (rails + sidekiq) | `chatwoot/chatwoot:v4.1.0` |
| Evolution API v2 | `atendai/evolution-api:v2.1.1` |
| Dify API / Worker | `langgenius/dify-api:1.13.3` |
| Dify Web | `langgenius/dify-web:1.13.3` |
| Dify Sandbox | `langgenius/dify-sandbox:0.2.14` |
| Dify Plugin Daemon | `langgenius/dify-plugin-daemon:0.5.3-local` |
| Dify SSRF Proxy | `ubuntu/squid:latest` |
| Prometheus | `prom/prometheus:v2.54.1` |
| Grafana | `grafana/grafana:11.3.0` |
| Middleware | build local (`node:22-alpine`) |

> Valide as tags no registry (`docker manifest inspect <img>`) antes do deploy — upstreams iteram rápido. Mantenha o pino sempre exato.

## Operação

- **Requisitos de infra:** 4 vCPU / 16 GB RAM (mínimo) para o tier shared.
- **Backup:** `./scripts/backup.sh` — agende via cron no host (ver `scripts/README.md`).
- **Observabilidade:** Grafana em `:3002`, dashboard `NexaDuo — Chat Services` pré-provisionado com token usage por `account_id`, latência Dify e erros.
- **Rate limiting & moderação:** configure no próprio Dify (*Orchestrate → Moderation*) e respeite os tiers da Meta.

## Próximos passos (roadmap)

Ver `docs/plans/first-setup.plan.md`. Itens que ficam fora desta primeira iteração:

- Tier **Dedicated** (stack Dify full por tenant via compose profile).
- Tier **Weaviate** opcional.
- Console API do Dify no `create-tenant.sh` (hoje é semi-manual).
- Exporter Postgres/Redis para Prometheus.
- Restore script interativo.
