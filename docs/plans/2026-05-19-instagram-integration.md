# Integração Instagram via Evolution API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrar o Instagram Direct Messages à stack NexaDuo utilizando a Evolution API v2 como bridge para o Chatwoot, permitindo que agentes de IA (Dify) respondam aos clientes.

**Architecture:** 
1. **Evolution API**: Cria uma instância do tipo `instagram`.
2. **Chatwoot**: Recebe as mensagens via "API Channel" (configurado automaticamente pela Evolution).
3. **Middleware**: Recebe webhooks do Chatwoot e encaminha para o Dify.
4. **Dify**: Processa a mensagem e retorna a resposta via Middleware -> Chatwoot -> Evolution -> Instagram.

**Tech Stack:** Evolution API v2.1.1, Chatwoot v3+, Node.js (Middleware), Dify.

---

### Task 1: Verificação de Infraestrutura

**Files:**
- Modify: `.env` (verify variables)
- Test: `scripts/health-check-all.sh`

- [ ] **Step 1: Verificar se a Evolution API está rodando**
Run: `curl -I http://localhost:8080/health` (ou URL pública se estiver em prod)
Expected: HTTP 200

- [ ] **Step 2: Validar chaves de API no .env**
Certifique-se de que `EVOLUTION_AUTHENTICATION_API_KEY` e `EVOLUTION_CHATWOOT_URL` estão corretos.

---

### Task 2: Criação da Instância Instagram na Evolution API

**Files:**
- Create: `scripts/provision-instagram.sh`

- [ ] **Step 1: Criar script de provisionamento**

```bash
#!/usr/bin/env bash
# scripts/provision-instagram.sh

INSTANCE_NAME=$1
CHATWOOT_ACCOUNT_ID=$2

if [ -z "$INSTANCE_NAME" ] || [ -z "$CHATWOOT_ACCOUNT_ID" ]; then
  echo "Usage: ./provision-instagram.sh <instance_name> <chatwoot_account_id>"
  exit 1
fi

API_KEY=$(grep EVOLUTION_AUTHENTICATION_API_KEY .env | cut -d '=' -f2)
EVO_URL="http://localhost:8080"

# 1. Create Instance
curl --location "$EVO_URL/instance/create" \
--header "apikey: $API_KEY" \
--header 'Content-Type: application/json' \
--data "{
    \"instanceName\": \"$INSTANCE_NAME\",
    \"token\": \"\",
    \"integration\": \"instagram\",
    \"qrcode\": false
}"

# 2. Configure Chatwoot Integration
curl --location "$EVO_URL/chatwoot/set/$INSTANCE_NAME" \
--header "apikey: $API_KEY" \
--header 'Content-Type: application/json' \
--data "{
    \"enabled\": true,
    \"accountId\": \"$CHATWOOT_ACCOUNT_ID\",
    \"url\": \"$EVOLUTION_CHATWOOT_URL\",
    \"token\": \"$CHATWOOT_API_TOKEN\",
    \"importMessages\": true,
    \"syncContact\": true
}"
```

- [ ] **Step 2: Dar permissão de execução**
Run: `chmod +x scripts/provision-instagram.sh`

---

### Task 3: Login e Conexão

- [ ] **Step 1: Realizar o login no Instagram via Evolution API**
A Evolution API para Instagram exige autenticação por usuário/senha ou via Manager (v2).
Use o endpoint `/instance/connect/instagram` para realizar o login se necessário, ou use o Dashboard da Evolution se disponível.

---

### Task 4: Provisionamento do Tenant no Middleware

**Files:**
- Modify: `middleware/tenants.json` (ou via CLI)

- [ ] **Step 1: Registrar o novo Account ID no Middleware**
Run: `npm run provision-tenant -- --slug instagram-bot --account-id <ACCOUNT_ID>` (no diretório `provisioning`)

- [ ] **Step 2: Validar o mapeamento no .env (TENANT_MAP)**
Se estiver usando `TENANT_MAP` em vez de DB, adicione a entrada correspondente.

---

### Task 5: Teste de ponta a ponta

- [ ] **Step 1: Enviar um Direct para o Instagram conectado**
- [ ] **Step 2: Verificar no Chatwoot se a mensagem chegou**
- [ ] **Step 3: Verificar nos logs do Middleware se o Dify foi acionado**
Run: `docker compose logs -f middleware`
- [ ] **Step 4: Confirmar se a resposta da IA chegou ao Instagram**

---

### Task 6: Documentação

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Adicionar seção sobre Instagram no README**
Documentar o uso do script `provision-instagram.sh`.
