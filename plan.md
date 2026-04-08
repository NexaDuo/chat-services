Aqui está o **Blueprint Técnico** atualizado. A grande mudança é a substituição do n8n pelo **Dify**, que assume o papel de "LLMOps" e motor agêntico.

O Dify é tecnicamente superior para RAG e Orquestração de Agentes, e a **Evolution API v2** possui integração nativa com ele, o que reduz a necessidade de "plumbing" manual de webhooks.

---

# Blueprint: Omnichannel AI Stack (Dify + Evolution + Chatwoot)

## 1. Stack Tecnológica (Referência 2026)

| Componente | Tecnologia | Papel na Arquitetura |
| :--- | :--- | :--- |
| **Interface de Atendimento** | Chatwoot (Official Latest) | CRM, gestão de tickets e transbordo humano |
| **Conectividade Meta** | Evolution API v2.3.7+ | Ponte WhatsApp/Instagram com integração nativa ao Dify |
| **Cérebro Agêntico / RAG** | **Dify.ai (Self-hosted)** | Gestão de bases de conhecimento (RAG), prompts e agentes |
| **Banco de Dados** | PostgreSQL + pgvector | Persistência do Chatwoot e banco vetorial do Dify |
| **Cache & Queue** | Redis | Gestão de sessões e filas de mensagens |
| **Modelos de Linguagem** | Azure OpenAI | Modelos GPT-5-mini ou GPT-4o-mini |

## 2. Estratégia de Multitenancy (Isolamento de Dados)

O Dify Community Edition (self-hosted) permite apenas **um workspace** por instalação. Para suportar múltiplos clientes de forma "barata" e isolada:

*   **Modelo Docker-per-tenant:** Assim como no n8n, utilizaremos um script para subir instâncias isoladas do Dify para cada cliente importante que exija soberania total de dados.
*   **Isolamento Chatwoot/Evolution:** Ambas suportam multitenancy nativa via `Account ID` e `Instance ID`.
*   **Identificador Único:** O `conversation_id` da Evolution API garante que o Dify mantenha a memória correta para cada contato de WhatsApp/Instagram individualmente.

## 3. Fluxo Agêntico e MCP (Model Context Protocol)

O Dify v1.6.0+ possui suporte nativo bidirecional ao **MCP**, permitindo capacidades avançadas:

*   **Dify como MCP Client:** O agente pode consumir ferramentas de servidores MCP externos (ex: Google Calendar, GitHub, ERPs) sem escrever código de integração.
*   **Dify como MCP Server:** Você pode expor seus workflows do Dify (ex: um fluxo de "Consulta de Saldo") como ferramentas para serem chamadas por outras IAs (incluindo o Claude Code durante o desenvolvimento).
*   **Tools Integradas:** Uso do nó "Tool" no Dify para disparar ações como: criar labels no Chatwoot, enviar e-mails ou atualizar planilhas via requisição HTTP.

## 4. Funcionamento da Integração (Sem Webhooks Manuais)

A Evolution API v2 simplifica o processo:
1.  **Configuração:** No painel da Evolution, você ativa o módulo Dify e insere a `API KEY` do aplicativo criado no Dify Studio.
2.  **Encaminhamento:** Toda mensagem que chega no WhatsApp/Instagram é enviada automaticamente para a API do Dify.
3.  **Processamento RAG:** O Dify consulta a base de documentos (PDFs, sites, Notion), gera a resposta e a devolve para a Evolution, que entrega ao usuário.
4.  **Handoff Humano:** Ao detectar uma intenção de transbordo (ex: palavra "humano" ou baixa confiança da IA), o Dify pode responder com uma tag específica que a Evolution interpreta para reabrir a conversa no Chatwoot.

## 5. Estrutura do Repositório (Claude Code Ready)

/chat-services
├── docker-compose.yml           # Serviços Globais: Chatwoot, Evolution, Redis, Postgres
├──.env.example                 # Segredos Meta, Azure e Super Admin
├── /dify                        # Configurações base do Dify (API, Worker, Web)
├── /infrastructure
│   └── /postgres                # Scripts init (pgvector)
├── /provisioning
│   └── deploy_new_client.sh     # Script para spawnar novos containers Dify/n8n se necessário
├── /dify-apps                   # Exportações DSL (YAML) dos prompts e RAG
└── /scripts                     # Utilitários de deploy (Coolify-ready)

## 6. Requisitos de Infraestrutura

Para rodar essa stack completa (Chatwoot + Evolution + Dify):
*   **CPU:** 4 vCPUs (Dify e Evolution exigem processamento constante para IA e mídias).
*   **RAM:** 8 GB a 16 GB (Recomendado 16 GB para suportar o Puppeteer da Evolution e o processamento de Knowledge do Dify).
*   **Disco:** 50 GB SSD (NVMe para performance de busca vetorial).

## 7. Portabilidade e Nuvem

*   **Coolify:** O repositório deve ser desenhado para ser importado no **Coolify**. Ele gerenciará os subdomínios (ex: `chat.empresa.com`, `api.empresa.com`, `dify.empresa.com`) e o SSL automaticamente via Let's Encrypt.
*   **Azure/AWS:** O deploy será feito via `docker-compose` em uma VM Linux simples nesses provedores, mantendo o custo fixo entre **$20 e $40/mês**.

---
*Este blueprint está pronto para ser entregue ao Claude Code. Ele foca na robustez do Dify para IA, na versatilidade da Evolution para canais e no poder de CRM do Chatwoot.*