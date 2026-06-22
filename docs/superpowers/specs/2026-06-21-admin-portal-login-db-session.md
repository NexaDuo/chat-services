# Design Spec: Database-Backed Admin Portal Authentication & Login

This document outlines the design for implementing database-backed user authentication and sessions in the Omnichannel Admin Portal (Fastify Middleware app).

---

## 1. Objectives & Requirements

- **Interactive Login**: Replace the browser's basic authentication popups with a visually stunning, premium login screen.
- **Relational User & Session Tables**: Separate users and sessions to support granular roles, permissions, and multiple accounts in the future (paving the way for middleware to serve as an SSO / OAuth provider).
- **tenants.yaml Integration**: Admin credentials will be configured in `tenants.yaml` under `global.admin.username` and `global.admin.password` and dynamically synchronized to the database.
- **Backwards Compatibility / Automation Migration**: Shift integration and Playwright tests to authenticate via cookie-based sessions instead of basic auth headers.

---

## 2. Architecture & Database Design

### Database Schema Migration
We will add two tables (`users` and `sessions`) in the `middleware` database inside `infrastructure/postgres/01-init.sql`:

```sql
CREATE TABLE IF NOT EXISTS users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  role TEXT DEFAULT 'admin',
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_token ON sessions(token);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions(expires_at);
```

### Sync Script Modifications (`scripts/sync-tenants.ts`)
1. Read the `global.admin` object from `tenants.yaml`:
   ```yaml
   global:
     gcp_project_id: "nexaduo-492818"
     base_domain: "nexaduo.com"
     admin:
       username: "admin"
       password: "secure-password"
   ```
2. During synchronization, hash the password using SHA-256 with a salt (using Node's native `crypto` library) and insert/update the `users` table:
   ```sql
   INSERT INTO users (username, password_hash, role)
   VALUES ($1, $2, 'admin')
   ON CONFLICT (username)
   DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP;
   ```

---

## 3. UI Implementation & Visual Aesthetics

### Login UI (`middleware/src/public/index.html`)
- **Theme**: Centered translucent glassmorphism login form container, indigo-to-emerald gradient button, dark background (`#090d16`) with radial glow blobs.
- **Structure**: Rendered in a new `#view-login` SPA section that displays if the user is unauthenticated.

### Client-Side Router
- On startup, the SPA fires `GET /admin/api/auth-status`.
- If the response is `401`, hide the main dashboard layout and display the login screen view `#view-login`.
- If `200`, display the main dashboard (landing list or active client panel).

---

## 4. API Endpoints

### 1. `GET /admin/api/auth-status`
- **Method**: GET
- **Logic**: Extract the `admin_session` cookie. Query `sessions` (joined with `users`) to verify if token is valid and not expired.
- **Response (200)**: `{ authenticated: true, username: "admin", role: "admin" }`
- **Response (401)**: `{ authenticated: false }`

### 2. `POST /admin/api/login`
- **Method**: POST
- **Payload**: `{ username, password }`
- **Logic**: Validate credentials against database `users` table. If valid:
  - Generate a secure random token: `crypto.randomBytes(32).toString('hex')`.
  - Store token and expiration (now + 24 hours) in `sessions` table.
  - Set cookie `admin_session=<token>; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400` in the response headers.
- **Response (200)**: `{ status: "success", username }`
- **Response (401)**: `{ error: "invalid_credentials" }`

### 3. `POST /admin/api/logout`
- **Method**: POST
- **Logic**: Delete the session token from the `sessions` table and clear the cookie by setting `Set-Cookie: admin_session=; Path=/; SameSite=Lax; Expires=Thu, 01 Jan 1970 00:00:00 GMT`.
- **Response (200)**: `{ status: "success" }`

---

## 5. Verification & Testing Strategy

- **Mock Session Queries**: Update Playwright tests in `onboarding/tests/15-admin-portal.spec.ts` to mock the query behavior of the `users` and `sessions` tables using `mockDb`.
- **Playwright Test Adapters**:
  - Implement a `loginAndGetCookie` helper that runs a POST login request on initialization.
  - Set the header `Cookie: admin_session=<token>` on all API requests.
  - Inject the cookie into the browser context `context.addCookies([{ name: 'admin_session', value: token, domain: '127.0.0.1', path: '/' }])` before rendering page views.
