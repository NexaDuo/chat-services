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

## Configuração:
O script lê as credenciais do arquivo `.env` na raiz do projeto:
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `CHATWOOT_FRONTEND_URL`
- `DIFY_CONSOLE_WEB_URL`
