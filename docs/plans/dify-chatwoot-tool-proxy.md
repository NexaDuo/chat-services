# Plano de Arquitetura: Proxy de Ferramentas (Dify → Middleware → Chatwoot)

Este documento descreve a estratégia para permitir que agentes do Dify atualizem informações no Chatwoot, em um ambiente multi-tenant, de forma segura, auditável e escalável.

> **Status:** Revisado como _API Gateway de Tools_, com isolamento por tenant, whitelist de campos e alinhamento ao padrão já existente em `/tools/handoff`.

## 1. Motivação e Contexto

Hoje o Dify precisa interagir com o Chatwoot para persistir dados coletados durante a conversa (nome, e-mail, atributos customizados, status). Em um cenário multi-tenant — onde cada cliente possui seu próprio App no Dify — configurar a ferramenta diretamente contra a API do Chatwoot em cada tenant apresenta riscos claros:

- **Exposição horizontal de credenciais:** o `CHATWOOT_API_TOKEN` (admin) ficaria replicado em N Apps do Dify, aumentando a superfície de ataque e impossibilitando rotação prática.
- **Ausência de isolamento entre tenants:** nada impede que o App do Tenant A chame a API do Chatwoot com o `account_id` do Tenant B.
- **Falta de governança:** o Middleware perde visibilidade sobre _quais_ ações de escrita o agente está executando, _em quais_ contatos, com _qual_ frequência.
- **Acoplamento ao contrato do Chatwoot:** qualquer mudança de endpoint / versão obriga atualização manual em todos os Apps.

## 2. Solução: Middleware como API Gateway de Tools

O Middleware expõe um conjunto reduzido e **intencionalmente restrito** de operações de escrita. O Dify nunca fala diretamente com o Chatwoot — ele chama o Middleware, que:

1. Autentica a chamada (shared secret, alinhado ao padrão `/tools/handoff`).
2. **Valida que o `account_id` do payload corresponde a um tenant conhecido** (`resolveTenant`).
3. Aplica **whitelist de campos** (sem pass-through arbitrário de payload).
4. Executa a chamada contra o Chatwoot usando o token admin guardado apenas no `.env` do Middleware.
5. Emite métrica Prometheus e log estruturado para auditoria.

### 2.1. Fluxo de Dados

```
Dify Agent/Chatflow
   │  POST /tools/chatwoot/update-contact
   │  Header: x-tool-secret: <HANDOFF_SHARED_SECRET>
   │  Body:   { account_id, contact_id, fields: { name?, email?, phone?, custom_attributes? } }
   ▼
Middleware (Fastify)
   ├─ Zod schema validation (whitelist estrita)
   ├─ Auth: timing-safe compare do shared secret
   ├─ resolveTenant(account_id)  ─▶  401 se account_id não está em TENANT_MAP
   ├─ Rate limit por (account_id, tool) — futuro
   ├─ Audit log estruturado (pino) + Prometheus counter
   ▼
Chatwoot REST API
   PUT /api/v1/accounts/{accountId}/contacts/{contactId}
   Header: api_access_token: <CHATWOOT_API_TOKEN>
```

### 2.2. Por que reusar `HANDOFF_SHARED_SECRET` (em vez de criar `TOOL_SECRET_KEY`)

O Middleware já possui um segredo compartilhado de alto valor (`HANDOFF_SHARED_SECRET`, mínimo de 16 chars, validado em `config.ts`). Criar um segundo segredo aumenta a superfície de rotação sem benefício de segurança — ambos dão acesso a ações destrutivas sobre o Chatwoot. A refatoração sugerida é **renomear a _semântica_** (não a env var) para `x-tool-secret` na documentação da tool, mantendo a env var `HANDOFF_SHARED_SECRET` e aceitando tanto `x-handoff-secret` quanto `x-tool-secret` durante a transição. A longo prazo, avaliar migração para **per-tenant signed JWTs** (ver §6).

## 3. Plano de Implementação

### 3.1. Extensão do `ChatwootClient`

Adicionar em `middleware/src/chatwoot.ts`:

```ts
async updateContact(params: {
  accountId: number | string;
  contactId: number | string;
  fields: {
    name?: string;
    email?: string;
    phone_number?: string;
    custom_attributes?: Record<string, unknown>;
  };
}): Promise<void>
```

- Método HTTP: `PUT /api/v1/accounts/{accountId}/contacts/{contactId}`.
- `custom_attributes` é **mesclado** pelo Chatwoot (merge semântico no lado do servidor), então uma atualização parcial é segura.
- Log `debug` com `{ accountId, contactId, fieldsChanged }` (sem valores, para não logar PII).

### 3.2. Novo handler: `handlers/tools-chatwoot.ts`

Criar rota `POST /tools/chatwoot/update-contact` — alinhada ao prefixo `/tools/*` já usado por `/tools/handoff`, **não** `/api/tools/*`.

Responsabilidades:

1. **Auth:** header `x-tool-secret` (ou `x-handoff-secret` para compat), comparação timing-safe (`crypto.timingSafeEqual`) para evitar side-channel.
2. **Validação Zod com whitelist estrita:**
   ```ts
   const UpdateContactBody = z.object({
     account_id: z.union([z.string(), z.number()]),
     contact_id: z.union([z.string(), z.number()]),
     fields: z.object({
       name: z.string().trim().min(1).max(255).optional(),
       email: z.string().email().max(255).optional(),
       phone_number: z.string().trim().min(5).max(32).optional(),
       custom_attributes: z.record(z.string(), z.union([
         z.string(), z.number(), z.boolean(), z.null()
       ])).optional(),
     }).refine((v) => Object.keys(v).length > 0, {
       message: "fields must contain at least one updatable property",
     }),
   }).strict();
   ```
   `.strict()` rejeita chaves desconhecidas no top-level. `custom_attributes` restringe valores a primitivos para evitar que o agente envie payloads estruturados arbitrários.
3. **Isolamento multi-tenant:** chamar `resolveTenant(config, account_id)`. Se `null`, responder `403 { error: "unknown_tenant" }` — impede que um prompt injection peça para escrever em outro account.
4. **Execução:** `chatwoot.updateContact(...)`, envelopada em try/catch.
5. **Observabilidade:**
   - `metrics.toolCallsTotal.inc({ account_id, tool: "update_contact", result: "ok"|"error" })`.
   - `req.log.info({ accountId, contactId, tool: "update_contact", fieldsChanged: Object.keys(fields) }, "tool: update_contact ok")`.
6. **Contrato de erro** (para o Dify interpretar):
   ```json
   { "ok": false, "error": "unknown_tenant" | "invalid_payload" | "chatwoot_error", "issues"?: [...] }
   ```

### 3.3. Métrica Prometheus

Adicionar em `middleware/src/metrics.ts`:

```ts
toolCallsTotal: new Counter({
  name: "middleware_tool_calls_total",
  help: "Tool proxy calls by tenant and outcome",
  labelNames: ["account_id", "tool", "result"],
});
```

Permite dashboards "top-N tenants por chamada de tool" e alertas em taxa de erro por tenant.

### 3.4. Custom Tool no Dify (Schema OpenAPI único e versionado)

Schema OpenAPI publicado em `dify-apps/tools/chatwoot-proxy.v1.yaml` (versionado no Git):

- `servers.url`: `https://<middleware-url>`
- `paths`: `/tools/chatwoot/update-contact` → `operationId: updateContact`
- `components.securitySchemes`: `ApiKeyAuth` (header `x-tool-secret`).
- `components.schemas`: espelha exatamente o Zod acima.
- `info.version: "1.0.0"` — bump a cada mudança incompatível; criar `/tools/chatwoot/update-contact/v2` ao invés de quebrar a v1 em produção.

Novos tenants **importam o mesmo arquivo** — o único ponto de configuração por tenant no Dify é a API Key (o shared secret).

### 3.5. Roadmap de escopo (incremental)

A v1 entrega **apenas** `update-contact`. Próximas operações, seguindo o mesmo padrão de handler/schema/métrica:

| Prioridade | Operação | Justificativa |
|---|---|---|
| **v1 (now)** | `update-contact` | Caso de uso primário (nome, e-mail, atributos de perfil). |
| v2 | `set-conversation-attributes` | Chatwoot já suporta (ver `chatwoot.ts`); comum para tag de funil/estágio. |
| v3 | `add-conversation-labels` | Segmentação por agente IA. |
| v4 | `search-contact` (leitura) | Dedupe de contatos antes de criar leads duplicados. |

Handoff permanece em `/tools/handoff` — **não** consolidar, pois tem contrato distinto (side-effects em status + label + nota privada).

## 4. Segurança — Checklist do Arquiteto

- [x] **Token admin do Chatwoot nunca sai do Middleware.**
- [x] **Isolamento de tenant enforced pelo `resolveTenant`**, não apenas por convenção no prompt do Dify.
- [x] **Whitelist estrita de campos** — zero pass-through de payload.
- [x] **Comparação timing-safe** do shared secret.
- [x] **Rejeita chaves desconhecidas** (`z.object(...).strict()`).
- [x] **Sem logging de PII** (só keys alteradas, nunca valores).
- [ ] **Rate limit por tenant** — adicionar `@fastify/rate-limit` com chave = `account_id` numa segunda iteração.
- [ ] **Rotação de credenciais** — migrar para JWT assinado por tenant (ver §6) quando houver >10 tenants.
- [ ] **Idempotência** — aceitar header opcional `Idempotency-Key` e deduplicar via Redis (SETNX + TTL 10min) se o Dify começar a repetir chamadas em retries.

## 5. Benefícios para Escala

- **Provisionamento:** novo tenant = 1 linha em `TENANT_MAP` + import do OpenAPI no App do Dify. Zero mudanças no Middleware.
- **Observabilidade central:** todas as escritas do agente IA passam por `middleware_tool_calls_total` com `account_id`, permitindo billing por uso e detecção de loops de agente.
- **Blast radius controlado:** comprometer o shared secret não expõe o token do Chatwoot, e rotacioná-lo é uma operação de Middleware (restart), não de N Apps do Dify.
- **Evolução desacoplada:** mudanças na API do Chatwoot são absorvidas internamente pelo `ChatwootClient`, invisíveis aos agentes.

## 6. Evolução Futura: Auth per-tenant com JWT

Quando o número de tenants ultrapassar ~10, ou quando houver requisito de rotação de credenciais sem downtime, migrar de "um shared secret global" para "JWTs curtos assinados pelo Middleware":

1. Middleware expõe `POST /auth/tool-token` (autenticado pelo shared secret atual) que retorna um JWT HS256 com `sub = account_id`, `exp = now + 1h`, `scope = ["update_contact"]`.
2. Dify armazena o token e renova via Custom Tool de refresh.
3. Handler de tool passa a validar `sub` do JWT contra o `account_id` do body (defesa em profundidade contra confused deputy).
4. Rotação = trocar a chave de assinatura; tokens antigos expiram naturalmente em ≤1h.

Esta evolução é **não-bloqueante** para v1 — deixada aqui como trilha para quando a operação justificar.

## 7. Critérios de Aceitação (v1)

- [ ] `ChatwootClient.updateContact` implementado e coberto por teste unitário com mock do axios.
- [ ] Handler `/tools/chatwoot/update-contact` rejeita: secret inválido (401), tenant desconhecido (403), payload fora do schema (400).
- [ ] Chamada válida retorna `{ ok: true }` e incrementa `middleware_tool_calls_total{result="ok"}`.
- [ ] Schema OpenAPI `dify-apps/tools/chatwoot-proxy.v1.yaml` commitado e importável no Dify sem edição manual.
- [ ] Smoke test em ambiente de staging: agente Dify atualiza `name` + `custom_attributes` de um contato real e o Chatwoot reflete a mudança.
- [ ] Log estruturado confirma ausência de PII (apenas `fieldsChanged: ["name", "custom_attributes"]`).
