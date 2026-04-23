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

4.  **Executar todos os testes de validação:**
    ```bash
    npm run test:all
    ```

### Atalhos na Raiz:
Para facilitar o ciclo completo (Clean -> Up -> Setup -> Test), você pode usar os comandos na raiz do projeto:
```bash
# Via script bash
./scripts/validate-stack.sh

# Via Makefile
make test
```

## Scripts Individuais:

1.  **Validar rota de instalação do Dify (Playwright):**
    ```bash
    npm run verify:dify-install
    ```

5.  **Validar login e acesso de conversa no Chatwoot (Playwright):**
    ```bash
    npm run verify:chatwoot-message
    ```

6.  **Validar acesso público e login no Grafana (Playwright):**
    ```bash
    npm run verify:grafana-access
    ```

## Configuração:
O script lê as credenciais do arquivo `.env` na raiz do projeto:
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `CHATWOOT_FRONTEND_URL`
- `DIFY_CONSOLE_WEB_URL`
- `CHATWOOT_ADMIN_EMAIL` (opcional; fallback: `ADMIN_EMAIL`)
- `CHATWOOT_ADMIN_PASSWORD` (opcional; fallback: `ADMIN_PASSWORD`)
- `CHATWOOT_ACCOUNT_ID` (opcional; força conta específica no smoke test de mensagens)
- `CHATWOOT_CONVERSATION_ID` (opcional; abre conversa específica quando o inbox está vazio no filtro)
- `CHATWOOT_CONTACT_HINT` (opcional; texto para localizar conversa quando não há card visível)
- `GRAFANA_URL` (opcional; default: `https://grafana.nexaduo.com`)
- `GRAFANA_ADMIN_USER`
- `GRAFANA_ADMIN_PASSWORD`
