Aqui está o **Blueprint Técnico** atualizado. A grande mudança é a substituição do n8n pelo **Dify**, que assume o papel de "LLMOps" e motor agêntico.

O Dify é tecnicamente superior para RAG e Orquestração de Agentes, e a **Evolution API v2** possui integração nativa com ele, o que reduz a necessidade de "plumbing" manual de webhooks.

---

# Blueprint: Omnichannel AI Stack (Dify + Evolution + Chatwoot)

## 1. Stack Tecnológica (Referência 2026)

| Componente | Tecnologia | Papel na Arquitetura |
| :--- | :--- | :--- |
| **Hub de Atendimento** | Chatwoot (Official Latest) | Inbox único, CRM, gestão de tickets e transbordo humano |
| **Conectividade Meta** | Evolution API v2 (v2.1.0+) | Ponte WhatsApp/Instagram — entrega mensagens ao Chatwoot |
| **Cérebro Agêntico / RAG** | **Dify.ai (Self-hosted, v1.2.0+)** | Gestão de bases de conhecimento (RAG), prompts e agentes |
| **Banco de Dados (app)** | PostgreSQL 16+ | Persistência do Chatwoot e do Dify (databases separados) |
| **Banco Vetorial** | **pgvector (extensão Postgres)** | **Decisão:** pgvector para Tier Shared (eficiência de recursos); Weaviate opcional para Tier Dedicated |
| **Cache & Queue** | Redis 7+ | Sessões, filas (Sidekiq do Chatwoot, Celery do Dify) |
| **Modelos de Linguagem** | Azure OpenAI | **Padrão:** `gpt-4o` (agente) e `gpt-4o-mini` (RAG/embeddings) |

> ⚠️ **Versões:** As versões acima são alvos para validação em 2026-04-08. O suporte a MCP (Model Context Protocol) no Dify v1.2+ é o pilar para integrações dinâmicas.

## 2. Estratégia de Multitenancy (Isolamento de Dados)

### 2.1. Restrição fundamental do Dify CE
O Dify Community Edition suporta **apenas um workspace por instalação**. Nossa arquitetura contorna isso via:

- **Tier Shared (Lógico):** Um Dify, múltiplos Apps. Cada cliente = um App Dify com sua própria API Key. Isolamento de RAG garantido por App.
- **Tier Dedicated (Físico):** Stack Dify completa isolada via Docker Compose.
- **Identificação:** O `account_id` do Chatwoot mapeia para o `DIFY_API_KEY` correspondente no middleware de integração.

### 2.2. Modelo Híbrido por Tiers

| Critério | Tier Shared | Tier Dedicated |
| :--- | :---: | :---: |
| **Isolamento** | Lógico (App ID) | Físico (Container/DB) |
| **Performance** | Recursos compartilhados | CPU/RAM garantidos |
| **Acesso ao Dify** | Apenas via API (gerenciado) | Acesso total ao Studio pelo cliente |
| **Uso Recomendado** | PMEs e Startups | Enterprise / Compliance (LGPD) |

## 3. Fluxo Agêntico e MCP (Model Context Protocol)

O Dify v1.2+ atua como um orquestrador MCP robusto:

*   **Dify como MCP Client:** O agente consulta ferramentas externas em tempo real.
    *   *Exemplo:* `mcp-server-postgres` para consultar o banco de pedidos do cliente.
    *   *Exemplo:* `mcp-server-google-calendar` para agendamentos automáticos.
*   **Dify como MCP Server:** Workflows complexos do Dify expostos como ferramentas para o Claude Code ou outros agentes internos.
*   **Workflow-as-a-Tool:** Uso de Dify Workflows para garantir respostas determinísticas em fluxos críticos (ex: cancelamento de assinatura) antes de devolver para o Chat de IA livre.

## 4. Funcionamento da Integração (O Loop de Mensagens)

O Chatwoot é o **Hub**, mas o Dify precisa de um "Adapter" para fechar o loop de resposta, já que o Agent Bot do Chatwoot espera uma resposta via API.

**Fluxo Detalhado:**
1.  **Entrada:** WhatsApp → Evolution → Chatwoot (Webhook `message_created`).
2.  **Trigger:** Chatwoot chama o **Dify Adapter** (um pequeno serviço Node.js ou um Dify Workflow via HTTP).
3.  **Processamento:**
    *   O Adapter identifica o `account_id` e seleciona a `DIFY_API_KEY`.
    *   Chama o Dify Chat API enviando o `conversation_id` (Chatwoot ID) e o `user` (`{account_id}:{contact_id}`).
4.  **Saída:** O Dify responde → O Adapter chama a API do Chatwoot (`/messages`) para postar a resposta na conversa.

**Handoff Humano:**
- Implementado como uma **Tool (HTTP Request)** no Dify.
- Quando o Dify decide pelo handoff:
    1. Chama `PUT /conversations/{id}` no Chatwoot para mudar status para `open`.
    2. Adiciona label `atendimento-humano`.
    3. Envia mensagem interna (private note) com o resumo do contexto da IA para o atendente.

## 5. Estrutura do Repositório

```
/chat-services
├── docker-compose.yml           # Stack Base: Chatwoot, Evolution, Redis, Postgres
├── .env.example                 # Configurações globais
├── /infrastructure
│   └── /postgres                # Init scripts (db_create, pgvector extension)
├── /middleware                  # Dify-Chatwoot Adapter (Node.js/TypeScript)
├── /dify                        # Dify Stack (API, Worker, Sandbox)
├── /dify-apps                   # Exports YAML dos agentes (Versionamento de Prompts)
└── /provisioning                # Scripts de automação de novos tenants
```

## 6. Requisitos de Infraestrutura (Shared Stack)

*   **CPU:** 4 vCPUs (mínimo), 8 vCPUs (ideal para 10+ tenants).
*   **RAM:** 16 GB (recomendado para acomodar Redis, Postgres e Dify Workers).
*   **Disco:** 50 GB NVMe (Performance de busca vetorial).
*   **OS:** Ubuntu 24.04 LTS (Coolify-ready).

## 7. Observabilidade e Custos

- **Monitoring:** Grafana + Prometheus monitorando o tamanho das filas do Sidekiq (Chatwoot) e Celery (Dify).
- **FinOps:** O Dify registra o uso de tokens por App. O Adapter deve logar o `account_id` + `token_usage` para faturamento/rate-limit por cliente.
- **Safety:** Implementação de `moderation` nodes no Dify para filtrar conteúdo sensível antes de chegar ao LLM.

## 8. Portabilidade e Nuvem

*   **Coolify:** O repositório é desenhado para ser importado no **Coolify**, que gerencia subdomínios (ex: `chat.empresa.com`, `api.empresa.com`, `dify.empresa.com`) e SSL automático via Let's Encrypt.
*   **Azure/AWS:** Deploy via `docker-compose` em uma VM Linux (Ubuntu 24.04 LTS), mantendo custo fixo entre **$20 e $40/mês** para a Shared Stack.

---
*Este blueprint está pronto para ser entregue ao Claude Code. Ele foca na robustez do Dify para IA, na versatilidade da Evolution para canais e no poder de CRM do Chatwoot, com Chatwoot como hub único e operação production-ready desde o dia zero.*