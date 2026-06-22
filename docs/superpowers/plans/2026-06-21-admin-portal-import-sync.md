# Discovery & Import/Sync Feature Plan for Omnichannel Admin Portal

This plan details the implementation of a "Discovery & Import/Sync" feature in the Omnichannel Admin Portal. This feature enables administrators to fetch existing accounts from Chatwoot and instances from Evolution API, compare them with the middleware's database mappings, and import/link them directly from the UI.

---

## Task 1: Playwright Test Scaffolding
Set up integration checks for discovery and import endpoints.

- [x] **Step 1.1: Scaffold Tests in `15-admin-portal.spec.ts`**
  Add test blocks verifying:
  * `GET /admin/api/tenants/:tenantSlug/discovery` returns a list of unmapped Chatwoot accounts alongside their status on Evolution API.
  * `POST /admin/api/tenants/:tenantSlug/import` validates parameters, inserts the account mapping into the database, and returns a `201 Created` status code.
  
- [x] **Step 1.2: Mock Chatwoot Platform API and Evolution API**
  Extend `mockAxios` in the spec file to support:
  * `GET /platform/api/v1/accounts` returning list of existing accounts (e.g. including some accounts not in `mockDb`).
  * `GET /instance/fetchInstances` returning Evolution instances.

---

## Task 2: Backend Discovery API Endpoints
Implement API routes in the Fastify Middleware service.

- [x] **Step 2.1: Implement GET `/admin/api/tenants/:tenantSlug/discovery`**
  * File: `middleware/src/handlers/admin.ts`
  * Logic:
    1. Retrieve the physical tenant config and its Platform API token from the database.
    2. Fetch all accounts from Chatwoot via `GET /platform/api/v1/accounts`.
    3. Query the `tenants` database table to find existing mappings.
    4. Fetch active instances from Evolution API via `GET /instance/fetchInstances`.
    5. Compare lists to identify:
       * **Unmapped Chatwoot Accounts:** Accounts present in Chatwoot but missing from the `tenants` database table.
       * **Evolution API Orphan Instances:** Instances present in Evolution API that are not mapped in the `tenants` table.
    6. Return a unified payload with:
       ```json
       {
         "unmappedAccounts": [
           { "id": "123", "name": "Existing Account Name" }
         ],
         "orphanInstances": [
           { "instanceName": "some-slug-instagram", "status": "open" }
         ]
       }
       ```

- [x] **Step 2.2: Implement POST `/admin/api/tenants/:tenantSlug/import`**
  * File: `middleware/src/handlers/admin.ts`
  * Logic:
    1. Accept payload:
       ```json
       {
         "chatwootAccountId": "123",
         "name": "Acme Corp",
         "subdomain": "acme",
         "difyApiKey": "dify-api-key",
         "difyAppType": "agent"
       }
       ```
    2. Validate input parameters (check subdomain availability, check that the account isn't already mapped).
    3. Insert the mapping into the `tenants` table.
    4. Ensure the corresponding Evolution API instance is created and linked. If it already exists, update its Chatwoot settings (`/chatwoot/set/:instanceName`). If it does not exist, create it.
    5. Handle errors and roll back DB inserts if Evolution setup fails.

---

## Task 3: UI Implementation (Discovery & Import Page)
Integrate the dashboard tab in the visual admin portal.

- [x] **Step 3.1: Add "Sincronização & Importação" Tab**
  * File: `middleware/src/public/index.html`
  * Add a tab button and a container section `import-sync-section` displaying:
    * List of discovered accounts in Chatwoot that are missing database mappings.
    * Form inputs/modal to import a selected account (asking for Subdomain, Dify API Key, and App Type).
    * Summary dashboard: Total Accounts in Chatwoot vs Mapped Accounts in database.

- [x] **Step 3.2: Implement Frontend JavaScript Handler**
  * File: `middleware/src/public/index.html`
  * Logic:
    * Fetch discovery data from `/admin/api/tenants/:tenantSlug/discovery` when the tab is clicked.
    * Render unmapped accounts inside a table.
    * Handle "Importar" button clicks, opening a modal to submit account configuration to `/admin/api/tenants/:tenantSlug/import`.
    * Show loading spinners, success toasts, and reload the accounts table on completion.

---

## Task 4: Validation and Verification
Ensure quality standards and verify in the CI/CD pipeline.

- [x] **Step 4.1: Run Local Tests**
  Run Playwright validation tests to verify backend logic and mock frontend rendering.
  *Command:*
  ```bash
  cd onboarding && npx playwright test tests/15-admin-portal.spec.ts
  ```

- [x] **Step 4.2: CI/CD Pipeline Checks**
  Commit changes, push branch, and ensure that staging E2E tests pass before merging.
