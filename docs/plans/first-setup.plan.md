# Blueprint: Omnichannel AI Stack (Dify + Evolution + Chatwoot)

This is the updated **Technical Blueprint**. The major change is the replacement of n8n with **Dify**, which takes over the role of "LLMOps" and agentic engine.

Dify is technically superior for RAG and Agent Orchestration, and **Evolution API v2** has native integration with it, reducing the need for manual webhook plumbing.

---

## 1. Technology Stack (2026 Reference)

| Component | Technology | Architectural Role |
| :--- | :--- | :--- |
| **Service Hub** | Chatwoot (Official Latest) | Unified inbox, CRM, ticket management, and human handoff |
| **Meta Connectivity** | Evolution API v2 (v2.1.0+) | WhatsApp/Instagram bridge — delivers messages to Chatwoot |
| **Agentic Brain / RAG** | **Dify.ai (Self-hosted, v1.2.0+)** | Knowledge base management (RAG), prompts, and agents |
| **App Database** | PostgreSQL 16+ | Persistence for Chatwoot and Dify (separate databases) |
| **Vector Database** | **pgvector (Postgres extension)** | **Decision:** pgvector for Tier Shared (resource efficiency); optional Weaviate for Tier Dedicated |
| **Cache & Queue** | Redis 7+ | Sessions, queues (Chatwoot Sidekiq, Dify Celery) |
| **Language Models** | Azure OpenAI | **Default:** `gpt-4o` (agent) and `gpt-4o-mini` (RAG/embeddings) |

> ⚠️ **Versions:** The versions above are targets for validation as of 2026-04-08. MCP (Model Context Protocol) support in Dify v1.2+ is the cornerstone for dynamic integrations.

## 2. Multitenancy Strategy (Data Isolation)

### 2.1. Fundamental Restriction of Dify CE
Dify Community Edition supports **only one workspace per installation**. Our architecture bypasses this via:

- **Tier Shared (Logical):** One Dify instance, multiple Apps. Each client = one Dify App with its own API Key. RAG isolation guaranteed per App.
- **Tier Dedicated (Physical):** Complete isolated Dify stack via Docker Compose.
- **Identification:** Chatwoot `account_id` maps to the corresponding `DIFY_API_KEY` in the integration middleware.

### 2.2. Hybrid Tier Model

| Criterion | Tier Shared | Tier Dedicated |
| :--- | :---: | :---: |
| **Isolation** | Logical (App ID) | Physical (Container/DB) |
| **Performance** | Shared resources | Guaranteed CPU/RAM |
| **Dify Access** | API only (managed) | Full Studio access for the client |
| **Recommended Use** | SMBs and Startups | Enterprise / Compliance (GDPR/LGPD) |

### 2.3. Production Routing and Multi-tenancy
The stack uses the following base domains in production:
- **Chatwoot:** `chat.nexaduo.com`
- **Dify:** `dify.nexaduo.com`

For multiple tenant support in the **Shared Stack**, future routing will be path-based:
- **Chatwoot:** `chat.nexaduo.com/{tenant}/`
- **Dify:** `dify.nexaduo.com/{tenant}/`

A Cloudflare Worker or Ingress Controller will be responsible for injecting the corresponding tenant headers.

## 3. Agentic Flow and MCP (Model Context Protocol)

Dify v1.2+ acts as a robust MCP orchestrator:

*   **Dify as MCP Client:** The agent consults external tools in real-time.
    *   *Example:* `mcp-server-postgres` to query the client's order database.
    *   *Example:* `mcp-server-google-calendar` for automated scheduling.
*   **Dify as MCP Server:** Complex Dify workflows exposed as tools for Claude Code or other internal agents.
*   **Workflow-as-a-Tool:** Use Dify Workflows to ensure deterministic responses in critical flows (e.g., subscription cancellation) before returning to the free AI Chat.

## 4. Integration Mechanics (The Message Loop)

Chatwoot is the **Hub**, but Dify needs an "Adapter" to close the response loop, as Chatwoot's Agent Bot expects an API-based response.

**Detailed Flow:**
1.  **Input:** WhatsApp → Evolution → Chatwoot (Webhook `message_created`).
2.  **Trigger:** Chatwoot calls the **Dify Adapter** (a small Node.js service or a Dify Workflow via HTTP).
3.  **Processing:**
    *   The Adapter identifies the `account_id` and selects the `DIFY_API_KEY`.
    *   Calls the Dify Chat API sending the `conversation_id` (Chatwoot ID) and `user` (`{account_id}:{contact_id}`).
4.  **Output:** Dify responds → Adapter calls Chatwoot API (`/messages`) to post the response in the conversation.

**Human Handoff:**
- Implemented as a **Tool (HTTP Request)** in Dify.
- When Dify decides on a handoff:
    1. Calls `PUT /conversations/{id}` in Chatwoot to change status to `open`.
    2. Adds the `atendimento-humano` label.
    3. Sends an internal message (private note) with a summary of the AI context for the agent.

## 5. Repository Structure

```
/chat-services
├── docker-compose.yml           # Base Stack: Chatwoot, Evolution, Redis, Postgres
├── .env.example                 # Global configurations
├── /infrastructure
│   └── /postgres                # Init scripts (db_create, pgvector extension)
├── /middleware                  # Dify-Chatwoot Adapter (Node.js/TypeScript)
├── /deploy                      # Deployment configurations
├── /dify-apps                   # Agent YAML exports (Prompt Versioning)
└── /provisioning                # New tenant automation scripts
```

## 6. Infrastructure Requirements (Shared Stack)

*   **CPU:** 4 vCPUs (minimum), 8 vCPUs (ideal for 10+ tenants).
*   **RAM:** 16 GB (recommended to accommodate Redis, Postgres, and Dify Workers).
*   **Disk:** 50 GB NVMe (Vector search performance).
*   **OS:** Ubuntu 24.04 LTS (Coolify-ready).

## 7. Observability and Costs

- **Monitoring:** Grafana + Prometheus monitoring Sidekiq (Chatwoot) and Celery (Dify) queue sizes.
- **FinOps:** Dify tracks token usage per App. The Adapter should log `account_id` + `token_usage` for client billing/rate-limiting.
- **Safety:** Implementation of `moderation` nodes in Dify to filter sensitive content before reaching the LLM.

## 8. Portability and Cloud

*   **Coolify:** The repository is designed to be imported into **Coolify** (`coolify.nexaduo.com`), which manages subdomains (e.g., `chat.nexaduo.com`, `dify.nexaduo.com`) and automatic SSL via Let's Encrypt.
*   **Azure/AWS:** Deploy via `docker-compose` on a Linux VM (Ubuntu 24.04 LTS), maintaining a fixed cost between **$20 and $40/month** for the Shared Stack.

---
*This blueprint is ready for delivery to Claude Code. It focuses on Dify's robustness for AI, Evolution's versatility for channels, and Chatwoot's CRM power, with Chatwoot as the single hub and production-ready operations from day zero.*
