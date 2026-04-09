# Provisionamento de tenants

Automação (semi-manual) para criar um novo tenant (cliente) no stack NexaDuo.

## Fluxo por tenant

1. **Chatwoot** — nova Account + usuário admin (via Platform API).
2. **Dify** — novo App no Studio com modelo + Knowledge Base; exportar DSL para `dify-apps/`.
3. **Middleware** — adicionar a nova entrada ao `TENANT_MAP` no `.env`.
4. **Evolution API** — criar instância do WhatsApp (QR code) pelo Manager e ativar integração com a nova account do Chatwoot.

## Pré-requisitos

- `jq`, `curl`, `openssl` no host.
- **Platform API token do Chatwoot**. Ele é *diferente* do `api_access_token` normal — precisa ser criado via Rails console (primeira vez apenas):

```bash
docker compose exec chatwoot-rails bundle exec rails runner \
  'p PlatformApp.create!(name: "provisioning").access_token.token'
# Copie o token retornado → export CHATWOOT_PLATFORM_TOKEN=...
```

Documentação oficial: [Chatwoot Platform API](https://developers.chatwoot.com/api-reference/platform).

## Uso do script

```bash
export CHATWOOT_URL=http://localhost:3000
export CHATWOOT_PLATFORM_TOKEN=<token>
export DIFY_URL=http://localhost:3001   # só cosmético, o script só printa

./provisioning/create-tenant.sh "Acme Corp" admin@acme.com "João Silva"
```

O script imprime o `account_id` criado e as instruções para finalizar o setup no Dify (ainda manual — a Console API do Dify não é estável o suficiente para automação 100%).

## Editar TENANT_MAP

O `TENANT_MAP` é um JSON de uma linha no `.env`:

```env
TENANT_MAP={"1":{"dify_api_key":"app-xxxxxx"},"2":{"dify_api_key":"app-yyyyyy","dify_base_url":"http://dify-api:5001/v1"}}
```

Após alterar:

```bash
docker compose restart middleware
docker compose logs -f middleware   # conferir "middleware: listening" + tenants=N
```

## Evolution API — nova instância WhatsApp

1. Abra `http://localhost:8080/manager` (use `EVOLUTION_AUTHENTICATION_API_KEY` como autenticação).
2. Crie uma nova instance, escolha Chatwoot como integração, aponte para `http://chatwoot-rails:3000` + `account_id` criado + token do bot user do Chatwoot.
3. Escaneie o QR code.

Alternativa via API (sem UI):

```bash
curl -sS -X POST http://localhost:8080/instance/create \
  -H "apikey: $EVOLUTION_AUTHENTICATION_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "instanceName": "acme-whatsapp",
    "qrcode": true,
    "chatwootAccountId": "1",
    "chatwootUrl": "http://chatwoot-rails:3000",
    "chatwootToken": "<token do bot user>",
    "chatwootSignMsg": true
  }'
```

## Offboarding

1. `docker compose exec chatwoot-rails bundle exec rails runner 'Account.find(<id>).destroy!'`
2. Remover app do Dify Studio + deletar o arquivo YAML correspondente em `dify-apps/`.
3. Remover entrada do `TENANT_MAP`, rodar `docker compose restart middleware`.
4. Remover instância no Evolution (`DELETE /instance/delete/{name}`).
