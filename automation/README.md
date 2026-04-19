# NexaDuo Stack - Automação de Setup

Este diretório contém scripts do Playwright para automatizar a configuração inicial dos serviços após subir o Docker Compose.

## O que este script faz:
1.  **Chatwoot:** Cria a primeira conta de administrador (Super Admin).
2.  **Dify:** Cria a conta inicial de administrador.

## Como usar:

1.  **Pré-requisitos:** Certifique-se de que a stack está rodando (`docker compose up -d`).
2.  **Instalar dependências:**
    ```bash
    cd automation
    npm install
    npx playwright install chromium
    ```
3.  **Executar o setup:**
    ```bash
    npm run setup
    ```

4.  **Validar rota de instalação do Dify (Playwright):**
    ```bash
    npm run verify:dify-install
    ```

5.  **Validar envio de mensagem no Chatwoot + evidência no middleware (Playwright):**
    ```bash
    npm run verify:chatwoot-message
    ```

## Configuração:
O script lê as credenciais do arquivo `.env` na raiz do projeto:
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `CHATWOOT_FRONTEND_URL`
- `DIFY_CONSOLE_WEB_URL`
- `CHATWOOT_ADMIN_EMAIL` (opcional; fallback: `ADMIN_EMAIL`)
- `CHATWOOT_ADMIN_PASSWORD` (opcional; fallback: `ADMIN_PASSWORD`)
- `GCP_PROJECT_ID` (opcional, default: `nexaduo-492818`)
- `GCP_ZONE` (opcional, default: `us-central1-b`)
- `GCP_VM_NAME` (opcional, default: `nexaduo-chat-services`)
