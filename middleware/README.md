<!-- generated-by: gsd-doc-writer -->
# Middleware — Chatwoot ⇄ Dify Adapter

Serviço Node.js/TypeScript (Fastify 5) que fecha o loop de mensagens entre o Chatwoot (hub) e o Dify (cérebro agêntico). É o único lugar onde a lógica de multitenancy por `account_id` é resolvida.

## URLs de Produção

- **Endpoint Webhook:** `https://api.nexaduo.com/webhooks/chatwoot` <!-- VERIFY: check if middleware is exposed at api.nexaduo.com -->
- **Endpoint Handoff:** `https://api.nexaduo.com/tools/handoff`

## Responsabilidades

1. **Webhook do Chatwoot** (`POST /webhooks/chatwoot`)
   - Filtra eventos: apenas `message_created` + `message_type: incoming` + sender `contact` + não-privado + conteúdo não-vazio.
   - Resolve tenant via `TENANT_MAP[account_id] → { dify_api_key, dify_base_url? }`.
   - Recupera `dify_conversation_id` salvo em `conversation.custom_attributes` para continuidade de memória.
   - Chama `POST {dify_base_url}/chat-messages` (modo `blocking`) com `user = "{account_id}:{contact_id}"` e `inputs` contendo os IDs do Chatwoot.
   - Posta a resposta do Dify de volta via `POST /api/v1/accounts/{id}/conversations/{id}/messages`.
   - Em caso de erro/timeout, posta uma **private note** no Chatwoot com contexto para o humano.

2. **Handoff HTTP Tool** (`POST /tools/handoff`)
   - Exposto para o Dify como uma HTTP Tool (header `x-handoff-secret: $HANDOFF_SHARED_SECRET`).
   - Abre a conversa (`toggle_status → open`), adiciona o label `atendimento-humano` e posta uma private note com o sumário do agente.

3. **Observabilidade** (`GET /metrics`)
   - Expõe métricas Prometheus: `middleware_dify_tokens_total{account_id,kind}`, `middleware_dify_requests_total{account_id,status}`, `middleware_dify_request_duration_seconds`, `middleware_errors_total`, `middleware_handoffs_total`, além das métricas padrão de Node.

## Variáveis de ambiente (ver `.env.example` na raiz)

| Var | Obrigatório | Descrição |
| :-- | :--: | :-- |
| `PORT` | não | Default `4000` |
| `LOG_LEVEL` | não | `trace\|debug\|info\|warn\|error\|fatal` — default `info` |
| `CHATWOOT_BASE_URL` | ✅ | URL interna do Chatwoot (ex: `http://chatwoot-rails:3000`) |
| `CHATWOOT_API_TOKEN` | ✅ | `api_access_token` de um usuário admin do Chatwoot |
| `DIFY_BASE_URL` | ✅ | URL interna do Dify (ex: `http://dify-api:5001/v1`) |
| `DIFY_REQUEST_TIMEOUT_MS` | não | Default `30000` |
| `TENANT_MAP` | ✅ | JSON: `{"<account_id>":{"dify_api_key":"app-..."}}` |
| `HANDOFF_SHARED_SECRET` | ✅ | Segredo ≥16 chars para o header `x-handoff-secret` |
| `HANDOFF_LABEL` | não | Default `atendimento-humano` |

> O `CHATWOOT_API_TOKEN` **só existe depois do primeiro setup** do Chatwoot. Crie o super-admin na UI (`chat.nexaduo.com`), copie o token em *Profile Settings → Access Token*, coloque no `.env` e rode `docker compose restart middleware`.

## Executar local (sem Docker)

```bash
cd middleware
npm install
npm run typecheck         # confirma que o TS compila
cp ../.env.example .env   # e preencha CHATWOOT_BASE_URL/TOKEN, DIFY_BASE_URL, etc.
npm run dev               # tsx watch — auto-reload
```

## Build + prod

```bash
npm run build    # dist/
npm run start    # node dist/index.js
```

Em produção o container roda via `docker compose up -d middleware` — ver `docker-compose.yml` na raiz.

## Rotas

- `POST /webhooks/chatwoot` — handler do webhook do Chatwoot
- `POST /tools/handoff` — HTTP Tool chamada pelo Dify (requer `x-handoff-secret`)
- `GET /health` — JSON `{ status: "ok", uptimeSeconds }`
- `GET /metrics` — exposição Prometheus (text/plain; version=0.0.4)

## Estrutura

```
src/
├── index.ts                       # Fastify bootstrap + graceful shutdown
├── config.ts                      # env validation (zod) + TENANT_MAP parser
├── logger.ts                      # pino (pretty em dev, JSON em prod)
├── metrics.ts                     # prom-client (registry + counters/histograms)
├── chatwoot.ts                    # client REST Chatwoot (axios)
├── dify.ts                        # client REST Dify Chat API (axios)
└── handlers/
    ├── health.ts                  # /health + /metrics
    ├── chatwoot-webhook.ts        # loop principal de mensagens
    └── handoff.ts                 # handoff humano (Dify tool)
```
