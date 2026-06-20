# Omnichannel Admin Portal Design Specification

**Date:** 2026-06-19  
**Status:** Approved  
**Topic:** Embedded administrative dashboard for account provisioning.

---

## 1. Goal
Provide a secure, web-based single-page application (SPA) embedded directly in the middleware adapter to simplify and automate client account management. 

Instead of manual SQL seeding or command-line scripting, administrators can use this interface to:
1. Create new client accounts and admin users in the active Chatwoot environment.
2. Insert client metadata/Dify mappings into the middleware's PostgreSQL `tenants` database table.
3. Automatically provision corresponding Instagram Direct (or WhatsApp) instances in the Evolution API.
4. Configure Chatwoot integration webhooks in the newly created Evolution API instances.

*Note: Infrastructure setup (like VM provisioning or launching new physical tenants) is strictly excluded and remains managed via Terraform and CI/CD pipelines.*

---

## 2. Architecture & Tech Stack
To minimize deployment complexity and resource consumption, the admin portal is completely self-contained within the existing **Middleware** (Node.js/Fastify) microservice.

```
                  +----------------------------------------+
                  |         Omnichannel Admin Portal       |
                  |     (Embedded SPA: HTML / CSS / JS)    |
                  +----------------------------------------+
                                      |
                                      | (Basic Auth Protected API)
                                      v
                  +----------------------------------------+
                  |          Middleware Adapter            |
                  |           (Fastify Server)             |
                  +----------------------------------------+
                     /                |                 \
                    /                 |                  \
                   v                  v                   v
      +-----------------+   +------------------+   +-------------------+
      |  Chatwoot API   |   |   Postgres DB    |   |   Evolution API   |
      | (Platform App)  |   | (tenants table)  |   | (v2.x.x Instance) |
      +-----------------+   +------------------+   +-------------------+
```

*   **Backend:** Fastify (Node.js/TypeScript) serving static files and API routes.
*   **Database:** PostgreSQL (reusing the existing PG pool connecting to the `middleware` database).
*   **Frontend:** Single-page dashboard built with raw HTML5, modern vanilla CSS (using sleek dark mode grids and glassmorphism), and asynchronous Vanilla JS (`fetch` requests).
*   **Security:** HTTP Basic Auth over TLS/HTTPS using a static password.

## 3. Route Definitions

All routes under `/admin` require HTTP Basic Access Authentication:

### 3.1. Static UI serving
*   **`GET /admin`**
    *   Serves the main landing page, listing cards for all active physical tenants and linking to `/admin/:tenantSlug`.
    *   Protected by Basic Auth.
*   **`GET /admin/:tenantSlug`**
    *   Serves the single-page admin dashboard for the selected physical tenant context.
    *   Protected by Basic Auth.
    *   The client-side JavaScript reads the `:tenantSlug` from `window.location.pathname` to lock the context, fetch matching accounts, and target the provisioning.

### 3.2. REST API Endpoints

*   **`GET /admin/api/tenants`**
    *   Retrieves the list of active physical tenants (environments) synced into the database.
    *   **Internal Query:** `SELECT DISTINCT ON (slug) slug, name, chatwoot_url, dify_url FROM tenants WHERE status = 'active' AND chatwoot_account_id = '1'`
    *   **Response (200 OK):**
        ```json
        [
          {
            "slug": "nexaduo",
            "name": "NexaDuo Main",
            "chatwootUrl": "https://chat.nexaduo.com",
            "difyUrl": "https://dify.nexaduo.com"
          },
          {
            "slug": "acme-dedicated",
            "name": "Acme Dedicated",
            "chatwootUrl": "https://chat.acme.com",
            "difyUrl": "https://dify.acme.com"
          }
        ]
        ```

*   **`GET /admin/api/tenants/:tenantSlug/accounts`**
    *   Retrieves client accounts registered under the selected physical tenant.
    *   **Internal Query:** Resolves the `chatwoot_url` of the physical tenant `tenantSlug`, then queries `SELECT * FROM tenants WHERE chatwoot_url = $1 AND chatwoot_account_id != '1' ORDER BY created_at DESC`
    *   **Response (200 OK):**
        ```json
        [
          {
            "slug": "miau-duda",
            "subdomain": "duda",
            "name": "Miau Duda",
            "chatwootAccountId": "12",
            "status": "active",
            "difyAppType": "chatflow"
          }
        ]
        ```

*   **`POST /admin/api/tenants/:tenantSlug/provision`**
    *   Creates a new account and associated integrations under the specified tenant context.
    *   **Request Payload:**
        ```json
        {
          "name": "Client Account Name",
          "email": "admin@clientdomain.com",
          "adminName": "Admin Contact Name",
          "subdomain": "client-slug",
          "difyApiKey": "app-XXXXXXXXXXXXXXXXXXXX",
          "difyAppType": "chatflow",
          "channelType": "instagram"
        }
        ```
    *   **Execution Flow (Atomic Logic):**
        1.  **Resolve Target URLs:** Middleware reads the target physical tenant using the `:tenantSlug` path parameter to obtain its `chatwoot_url` and `dify_url`.
        2.  **Chatwoot Account & User:** Triggers Chatwoot Platform API calls (`POST /platform/api/v1/accounts` and `POST /platform/api/v1/users`) targeting the resolved `chatwoot_url` using the matching Platform API Token (resolved dynamically based on the environment or the local `.env` configuration).
        3.  **Database Mapping:** Inserts a row into the `tenants` table of the `middleware` database mapping the new `chatwoot_account_id` and subdomain slug, and stores the `chatwoot_url` and `dify_url` of the selected tenant.
        4.  **Evolution Instance:** Sends a creation request (`POST /instance/create` with `integration: "instagram"`) to the Evolution API.
        5.  **Chatwoot Webhook Configuration:** Configures Chatwoot integration for that instance (`POST /chatwoot/set/:instanceName`) mapping webhook events back to the resolved `chatwoot_url`.
    *   **Response (201 Created):**
        ```json
        {
          "status": "success",
          "accountId": "12",
          "instanceName": "client-slug-instagram",
          "message": "Account created and instance initialized under selected tenant."
        }
        ```

*   **`GET /admin/api/instances/:name/status`**
    *   Checks the connection status of the Evolution API instance.
    *   **Internal Query:** Calls `GET /instance/connectionState/:name` on the Evolution API.
    *   **Response (200 OK):**
        ```json
        {
          "instanceName": "client-slug-instagram",
          "connectionState": "connected" 
        }
        ```

---

## 4. Security & Error Handling

### 4.1. Authentication
*   **Basic Auth Credentials:**
    *   Username: `admin`
    *   Password: Loaded from the environment variable `ADMIN_PASSWORD` (falls back to `HANDOFF_SHARED_SECRET` if not specified).
*   **Transport Security:** Only accessible via HTTPS in production. The dashboard passes through the Traefik router, which terminates SSL/TLS.

### 4.2. Rollbacks on Failure
To prevent orphaned resources:
*   If Chatwoot account creation fails, the API terminates immediately and returns an error payload (e.g. `400 Bad Request` or `502 Bad Gateway`).
*   If Evolution API instance registration fails after Chatwoot succeeded, the middleware:
    1. Removes any matching records inserted into the `tenants` table.
    2. Logs the failure and returns `502 Bad Gateway`.
    3. Displays the failure reason to the administrator in the UI so they can correct the parameters.

---

## 5. File Layout

The following directories and files will be added to the `middleware` service:

```
middleware/
├── src/
│   ├── handlers/
│   │   ├── admin.ts       # Router, Basic Auth logic, and /admin/api handlers
│   └── public/
│       └── index.html     # Single-page visual admin interface (dark mode CSS/JS)
```

---

## 6. Testing Plan
To validate the Admin Portal, we will add a Playwright test specification file:
*   **Location:** `onboarding/tests/15-admin-portal.spec.ts`
*   **Flow:**
    1.  Navigate to the `/admin` path and verify it prompts for credentials.
    2.  Authenticate using the correct `admin` username and `ADMIN_PASSWORD`.
    3.  Assert the "Provision New Client" form is visible and input fields are active.
    4.  Fill in test inputs and submit the form.
    5.  Mock/Assert backend endpoints handle the orchestration securely and list the newly created tenant in the active accounts table.
