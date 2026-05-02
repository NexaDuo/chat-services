# NexaDuo Stack - Setup Automation

This directory contains Playwright scripts to automate the initial configuration of services after starting Docker Compose.

## What this script does:
1.  **Chatwoot:** Creates the first administrator account (Super Admin).
2.  **Dify:** Creates the initial administrator account.

## How to use:

1.  **Prerequisites:** Ensure the stack is running (`docker compose up -d`).
2.  **Install dependencies:**
    ```bash
    cd onboarding
    npm install
    npx playwright install chromium
    ```
3.  **Execute setup:**
    ```bash
    npm run setup
    ```

4.  **Execute all validation tests:**
    ```bash
    npm run test:all
    ```

### Root Shortcuts:
To facilitate the full cycle (Clean -> Up -> Setup -> Test), you can use the commands at the project root:
```bash
# Via bash script
./scripts/validate-stack.sh

# Via Makefile
make test
```

## Individual Scripts:

1.  **Validate Dify installation route (Playwright):**
    ```bash
    npm run verify:dify-install
    ```

5.  **Validate login and conversation access in Chatwoot (Playwright):**
    ```bash
    npm run verify:chatwoot-message
    ```

6.  **Validate public access and login in Grafana (Playwright):**
    ```bash
    npm run verify:grafana-access
    ```

## Configuration:
The script reads credentials from the `.env` file at the project root:
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `CHATWOOT_FRONTEND_URL`
- `DIFY_CONSOLE_WEB_URL`
- `CHATWOOT_ADMIN_EMAIL` (optional; fallback: `ADMIN_EMAIL`)
- `CHATWOOT_ADMIN_PASSWORD` (optional; fallback: `ADMIN_PASSWORD`)
- `CHATWOOT_ACCOUNT_ID` (optional; forces specific account in message smoke test)
- `CHATWOOT_CONVERSATION_ID` (optional; opens specific conversation when inbox is empty in filter)
- `CHATWOOT_CONTACT_HINT` (optional; text to locate conversation when no card is visible)
- `GRAFANA_URL` (optional; default: `https://grafana.nexaduo.com`)
- `GRAFANA_ADMIN_USER`
- `GRAFANA_ADMIN_PASSWORD`
