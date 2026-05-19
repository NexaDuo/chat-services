# Instagram Integration via Evolution API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate Instagram Direct Messages to the NexaDuo stack using Evolution API v2 as a bridge to Chatwoot, allowing AI agents (Dify) to respond to customers.

**Architecture:** 
1. **Evolution API**: Creates an instance of type `instagram`.
2. **Chatwoot**: Receives messages via "API Channel" (automatically configured by Evolution).
3. **Middleware**: Receives webhooks from Chatwoot and forwards them to Dify.
4. **Dify**: Processes the message and returns the response via Middleware -> Chatwoot -> Evolution -> Instagram.

**Tech Stack:** Evolution API v2.1.1, Chatwoot v3+, Node.js (Middleware), Dify.

---

### Task 1: Infrastructure Verification

**Files:**
- Modify: `.env` (verify variables)
- Test: `scripts/health-check-all.sh`

- [ ] **Step 1: Verify if Evolution API is running**
Run: `curl -I http://localhost:8080/health` (or public URL if in production)
Expected: HTTP 200

- [ ] **Step 2: Validate API keys in .env**
Ensure that `EVOLUTION_AUTHENTICATION_API_KEY` and `EVOLUTION_CHATWOOT_URL` are correct.

---

### Task 2: Create Instagram Instance in Evolution API

**Files:**
- Create: `scripts/provision-instagram.sh`

- [ ] **Step 1: Create provisioning script**

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

- [ ] **Step 2: Give execution permission**
Run: `chmod +x scripts/provision-instagram.sh`

---

### Task 3: Login and Connection

- [ ] **Step 1: Login to Instagram via Evolution API**
The Evolution API for Instagram requires authentication via user/password or via Manager (v2).
Use the endpoint `/instance/connect/instagram` to log in if necessary, or use the Evolution Dashboard if available.

---

### Task 4: Tenant Provisioning in Middleware

**Files:**
- Modify: `middleware/tenants.json` (or via CLI)

- [ ] **Step 1: Register the new Account ID in Middleware**
Run: `npm run provision-tenant -- --slug instagram-bot --account-id <ACCOUNT_ID>` (in `provisioning` directory)

- [ ] **Step 2: Validate the mapping in .env (TENANT_MAP)**
If using `TENANT_MAP` instead of DB, add the corresponding entry.

---

### Task 5: End-to-End Test

- [ ] **Step 1: Send a Direct message to the connected Instagram**
- [ ] **Step 2: Verify in Chatwoot if the message arrived**
- [ ] **Step 3: Verify in Middleware logs if Dify was triggered**
Run: `docker compose logs -f middleware`
- [ ] **Step 4: Confirm if the AI response arrived on Instagram**

---

### Task 6: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add Instagram section to README**
Document the usage of the `provision-instagram.sh` script.
