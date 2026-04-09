#!/usr/bin/env bash
# =============================================================================
# create-tenant.sh — bootstrap de um novo tenant NexaDuo
# -----------------------------------------------------------------------------
# O que faz (1ª versão — semi-manual):
#   1. Cria uma Account no Chatwoot via Platform API.
#   2. Imprime as instruções para criar o App no Dify Studio (ainda manual —
#      o Dify Console API não é estável o bastante para automação full).
#   3. Mostra a linha JSON para adicionar em TENANT_MAP no `.env`.
#
# Pré-requisitos:
#   - Chatwoot rodando em $CHATWOOT_URL (default http://localhost:3000)
#   - Platform API access token do Chatwoot em $CHATWOOT_PLATFORM_TOKEN
#     (gere via Rails console ou Super Admin UI — veja provisioning/README.md)
#   - jq instalado
#
# Uso:
#   ./create-tenant.sh "Acme Corp" admin@acme.com "João Silva"
# =============================================================================
set -euo pipefail

: "${CHATWOOT_URL:=http://localhost:3000}"
: "${CHATWOOT_PLATFORM_TOKEN:?defina CHATWOOT_PLATFORM_TOKEN com o platform_app access_token}"

if [[ $# -lt 3 ]]; then
  cat <<USAGE
Uso: $0 "<account_name>" "<admin_email>" "<admin_full_name>"

Exemplo:
  $0 "Acme Corp" admin@acme.com "João Silva"

Variáveis (podem ir no ambiente):
  CHATWOOT_URL              default http://localhost:3000
  CHATWOOT_PLATFORM_TOKEN   obrigatório (veja provisioning/README.md)
USAGE
  exit 1
fi

ACCOUNT_NAME="$1"
ADMIN_EMAIL="$2"
ADMIN_NAME="$3"

command -v jq >/dev/null || { echo "ERROR: jq não encontrado. Instale antes."; exit 1; }

echo "==> Criando account no Chatwoot: ${ACCOUNT_NAME}"
ACCOUNT_RESP=$(curl -sS -X POST \
  "${CHATWOOT_URL}/platform/api/v1/accounts" \
  -H "Content-Type: application/json" \
  -H "api_access_token: ${CHATWOOT_PLATFORM_TOKEN}" \
  -d "$(jq -nc --arg name "$ACCOUNT_NAME" '{name: $name}')")

ACCOUNT_ID=$(echo "$ACCOUNT_RESP" | jq -r '.id // empty')
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: falha ao criar account. Resposta:"
  echo "$ACCOUNT_RESP" | jq .
  exit 1
fi
echo "    ✓ account_id=${ACCOUNT_ID}"

echo "==> Criando usuário admin: ${ADMIN_EMAIL}"
USER_RESP=$(curl -sS -X POST \
  "${CHATWOOT_URL}/platform/api/v1/users" \
  -H "Content-Type: application/json" \
  -H "api_access_token: ${CHATWOOT_PLATFORM_TOKEN}" \
  -d "$(jq -nc \
        --arg name "$ADMIN_NAME" \
        --arg email "$ADMIN_EMAIL" \
        --arg password "$(openssl rand -hex 16)" \
        '{name:$name, email:$email, password:$password}')")
USER_ID=$(echo "$USER_RESP" | jq -r '.id // empty')
if [[ -z "$USER_ID" ]]; then
  echo "ERROR: falha ao criar usuário. Resposta:"
  echo "$USER_RESP" | jq .
  exit 1
fi
echo "    ✓ user_id=${USER_ID}"

echo "==> Vinculando usuário à account (role=administrator)"
curl -sS -X POST \
  "${CHATWOOT_URL}/platform/api/v1/accounts/${ACCOUNT_ID}/account_users" \
  -H "Content-Type: application/json" \
  -H "api_access_token: ${CHATWOOT_PLATFORM_TOKEN}" \
  -d "$(jq -nc --arg uid "$USER_ID" '{user_id:($uid|tonumber), role:"administrator"}')" \
  > /dev/null
echo "    ✓ vinculado"

cat <<NEXT

==============================================================================
Account criada. Próximos passos (manuais):

  1. Abra o Dify Studio em ${DIFY_URL:-http://localhost:3001}
  2. Crie um novo App (Chatflow ou Agent) para "${ACCOUNT_NAME}"
  3. Configure o modelo (Azure OpenAI gpt-4o) + Knowledge Base
  4. Em 'Access API', copie a Service API Key (formato app-XXXXXXXX)
  5. Exporte a DSL e salve em dify-apps/${ACCOUNT_NAME// /-}__agent.yml
  6. Adicione ao TENANT_MAP do .env:

TENANT_MAP={"${ACCOUNT_ID}":{"dify_api_key":"app-PASTE-HERE"}}

  7. Aplique: docker compose restart middleware
  8. Valide: curl -s http://localhost:4000/health

Login do admin no Chatwoot: use "Esqueci minha senha" no ${CHATWOOT_URL}
(a senha foi gerada aleatoriamente).
==============================================================================
NEXT
