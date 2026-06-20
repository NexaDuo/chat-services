# Omnichannel Admin Portal Implementation Plan

This plan guides the step-by-step coding and verification of the embedded Administrative Portal. It follows a **Test-Driven / E2E-First** methodology, starting with Playwright test scaffolding to validate routes and UI flows incrementally.

---

## Task 1: Playwright Test Scaffolding
Set up the verification framework before writing production code.

- [x] **Step 1.1: Create Test File**
  Create a new Playwright test file at `onboarding/tests/15-admin-portal.spec.ts`.
  
- [x] **Step 1.2: Add Basic Authentication Test Cases**
  Define a test case in `15-admin-portal.spec.ts` to assert that accessing `/admin` or `/admin/any-slug` without basic auth credentials returns a `401 Unauthorized` status code.
  
- [x] **Step 1.3: Run Verification**
  Run the test to ensure it fails with `404 Not Found` (since the handler is not yet implemented, proving the test runner is active).
  *Command:*
  ```bash
  cd onboarding && npx playwright test 15-admin-portal.spec.ts
  ```

---

## Task 2: Backend Authentication and Basic UI Route Serving
Implement the route shell and security controls in the Middleware.

- [x] **Step 2.1: Implement Basic Auth Helper**
  Write a middleware/helper in `middleware/src/handlers/admin.ts` to parse the `Authorization` header and validate it against the `ADMIN_PASSWORD` (fallback: `HANDOFF_SHARED_SECRET`) environment variable.

- [x] **Step 2.2: Add Static Directory Configuration**
  Configure Fastify to serve static files from `src/public` using `@fastify/static` or direct handlers in `middleware/src/index.ts`.

- [x] **Step 2.3: Implement UI Handlers**
  Create the handlers in `middleware/src/handlers/admin.ts` for:
  *   `GET /admin` (serves the landing index.html)
  *   `GET /admin/:tenantSlug` (serves the dashboard index.html)
  
- [x] **Step 2.4: Create Skeleton index.html**
  Create a minimal skeleton HTML file at `middleware/src/public/index.html` containing `<h1>Admin Portal Loaded</h1>`.

- [x] **Step 2.5: Register Routes**
  Register the admin handler in the Fastify boot sequence in `middleware/src/index.ts`.

- [x] **Step 2.6: Verify Auth via Playwright**
  Add a test to verify that accessing `/admin` with correct credentials (`admin` / `ADMIN_PASSWORD` from environment) returns a `200 OK` status and loads the skeleton HTML, while wrong credentials return `401`.
  *Command:*
  ```bash
  cd onboarding && npx playwright test 15-admin-portal.spec.ts
  ```

---

## Task 3: REST API Endpoints
Implement database queries and external service orchestration.

- [x] **Step 3.1: Implement GET `/admin/api/tenants`**
  Add route and handler to fetch active physical tenants from the database (`chatwoot_account_id = '1'`).
  *Verify:* Call endpoint with curl and assert JSON list response.

- [x] **Step 3.2: Implement GET `/admin/api/tenants/:tenantSlug/accounts`**
  Add route to fetch client accounts sharing the same physical tenant base URL.
  *Verify:* Call endpoint and verify returns empty list or existing synced accounts.

- [x] **Step 3.3: Implement POST `/admin/api/tenants/:tenantSlug/provision`**
  Write the atomic provisioning orchestration:
  1. Fetch tenant base URLs for `:tenantSlug` from database.
  2. Call Chatwoot Platform API to create the account and user admin.
  3. Insert the new mapping row in the `tenants` DB table.
  4. Call Evolution API to create the Instagram instance (`/instance/create`) and set up webhook integration (`/chatwoot/set/:instanceName`).
  5. If any downstream call fails, execute DB/API rollbacks to keep states clean.

- [x] **Step 3.4: Implement GET `/admin/api/instances/:name/status`**
  Add route to check the connection status of the instance by forwarding requests to Evolution API's `/instance/connectionState/:name`.

- [x] **Step 3.5: Expand Playwright Verification**
  Extend E2E tests to mock Chatwoot and Evolution APIs and verify that calling `/admin/api/tenants/:tenantSlug/provision` successfully inserts the tenant and registers instances.
  *Command:*
  ```bash
  cd onboarding && npx playwright test 15-admin-portal.spec.ts
  ```

---

## Task 4: UI Dashboard Development
Construct the visual interface in HTML, CSS, and JavaScript.

- [x] **Step 4.1: Write Dashboard HTML/CSS Layout**
  Implement the responsive layout in `middleware/src/public/index.html` using modern dark mode CSS grids and glassmorphism. Include:
  *   Tenant selector landing page/cards.
  *   Provision form (Account Name, Email, Admin Name, Subdomain, Dify Key, App Type).
  *   Client accounts table (Name, Subdomain, Status badge, action button).
  *   Modal for connecting Instagram (with dynamic Status check button).

- [x] **Step 4.2: Add Client-Side JavaScript Logic**
  Write asynchronous JS inside `index.html` to:
  *   Read context slug from `window.location.pathname`.
  *   Fetch account list and render rows dynamically.
  *   Handle form submit, showing progress indicators, inline errors, and successful account credentials.
  *   Fetch and poll Instagram connection status.

- [x] **Step 4.3: Full E2E Test Suite Run**
  Run the full suite of E2E validation tests to verify authentication, listing, form input validation, form submission, and status polling.
  *Command:*
  ```bash
  cd onboarding && npx playwright test 15-admin-portal.spec.ts
  ```

---

## Task 5: CI/CD Deployment Integration
Ensure the tests run automatically in the pipeline and local stacks build cleanly.

- [x] **Step 5.1: Update deploy.yml workflow**
  Add `15-admin-portal.spec.ts` to the list of test specs executed during the `validate` job in `.github/workflows/deploy.yml`.

- [x] **Step 5.2: Local Environment Dry Run**
  Verify everything starts and tests pass locally (simulated via Playwright's local server and network mock validation since Docker engine is bypassed locally on WSL):
  *Command:*
  ```bash
  ./scripts/validate-stack.sh
  ```
