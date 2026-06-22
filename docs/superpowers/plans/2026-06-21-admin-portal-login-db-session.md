# Database-Backed Admin Portal Login Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a database-backed session authentication system for the omnichannel admin portal, complete with user/session tables, an interactive login page, configuration from `tenants.yaml`, and updated E2E playwright verification.

**Architecture:** We will create `users` and `sessions` tables in the Postgres database. The credentials will be loaded from `tenants.yaml` and upserted during synchronization. The Fastify backend will verify cookies against active sessions, and serve a single-page index containing login views if unauthenticated.

**Tech Stack:** Fastify (Node.js/TypeScript), Postgres, Playwright (E2E), HTML5/CSS3.

---

### Task 1: Database Migration Setup

**Files:**
- Modify: `infrastructure/postgres/01-init.sql`
- Test: Re-run Postgres Docker initialization or manually verify schema in DB.

- [ ] **Step 1.1: Append User & Session tables to 01-init.sql**
  Append the tables inside the `middleware` connect database section.
  
  ```sql
  -- users table
  CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT 'admin',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
  );

  -- sessions table
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

- [ ] **Step 1.2: Commit the migration script changes**
  Run: `git add infrastructure/postgres/01-init.sql && git commit -m "migration: create users and sessions tables for admin auth"`

---

### Task 2: Sync Script Credentials Upsert

**Files:**
- Modify: `scripts/sync-tenants.ts`
- Modify: `tenants.yaml`
- Test: `npm run tenants:sync` and check DB contents.

- [ ] **Step 2.1: Add global admin config to tenants.yaml**
  Modify `/home/ubuntu-24/repos/NexaDuo/chat-services/tenants.yaml` to include the admin block:
  ```yaml
  global:
    gcp_project_id: "nexaduo-492818"
    base_domain: "nexaduo.com"
    admin:
      username: "admin"
      password: "secure-password-123"
  ```

- [ ] **Step 2.2: Implement admin user upsert logic in scripts/sync-tenants.ts**
  Import `crypto` and add type definitions and queries to read `global.admin` and upsert it into the database:
  ```typescript
  import crypto from 'crypto';

  // Inside buildSeedSql:
  if (config.global.admin) {
    const pwdHash = crypto.createHash('sha256').update(config.global.admin.password).digest('hex');
    rows.push(`INSERT INTO users (username, password_hash, role)
VALUES ('${config.global.admin.username}', '${pwdHash}', 'admin')
ON CONFLICT (username)
DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP;`);
  }

  // Inside main():
  if (!skipDbSync && config.global.admin) {
    const { username, password } = config.global.admin;
    const pwdHash = crypto.createHash('sha256').update(password).digest('hex');
    const connectionString = process.env.DATABASE_URL;
    if (connectionString) {
      await withRetry('admin user sync', 5, async () => {
        const pool = new Pool({ connectionString, connectionTimeoutMillis: 10000 });
        try {
          await pool.query(
            `INSERT INTO users (username, password_hash, role)
             VALUES ($1, $2, 'admin')
             ON CONFLICT (username)
             DO UPDATE SET password_hash = EXCLUDED.password_hash, updated_at = CURRENT_TIMESTAMP`,
            [username, pwdHash]
          );
          logger.log(`\u2705 Synced Admin User in DB: ${username}`);
        } finally {
          await pool.end();
        }
      });
    }
  }
  ```

- [ ] **Step 2.3: Verify sync executes successfully**
  Run: `npm run tenants:sync -- staging`
  Expected: Upsert completes successfully and prints Admin User sync validation log.

- [ ] **Step 2.4: Commit sync updates**
  Run: `git add tenants.yaml scripts/sync-tenants.ts && git commit -m "feat(sync): support syncing admin credentials from tenants.yaml to DB"`

---

### Task 3: Backend Authentication & Route Refactoring

**Files:**
- Modify: `middleware/src/handlers/admin.ts`
- Test: Compile using `npm run typecheck` in `/middleware`.

- [ ] **Step 3.1: Change checkAuth to async and enforce DB sessions**
  Modify `/home/ubuntu-24/repos/NexaDuo/chat-services/middleware/src/handlers/admin.ts`:
  ```typescript
  const checkAuth = async (request: FastifyRequest, reply: FastifyReply): Promise<boolean> => {
    const cookieHeader = request.headers.cookie || "";
    const match = cookieHeader.match(/admin_session=([^;]+)/);
    const token = match ? match[1] : null;

    if (!token) {
      if (request.url.startsWith("/admin/api/")) {
        void reply.code(401).send({ error: "unauthorized" });
      } else {
        void reply.redirect("/admin/login");
      }
      return false;
    }

    try {
      const result = await pool.query(
        `SELECT s.id, u.username, u.role
         FROM sessions s
         JOIN users u ON s.user_id = u.id
         WHERE s.token = $1 AND s.expires_at > CURRENT_TIMESTAMP
         LIMIT 1`,
        [token]
      );

      if (result.rows.length === 0) {
        if (request.url.startsWith("/admin/api/")) {
          void reply.code(401).send({ error: "unauthorized" });
        } else {
          void reply.redirect("/admin/login");
        }
        return false;
      }
      (request as any).user = {
        username: result.rows[0].username,
        role: result.rows[0].role
      };
    } catch (err) {
      app.log.error({ err }, "Database session check failed");
      void reply.code(500).send({ error: "internal_server_error" });
      return false;
    }

    return true;
  };
  ```

- [ ] **Step 3.2: Update all admin routes to await checkAuth**
  Prepend `await` to `checkAuth(request, reply)` call inside every GET/POST handler route in `admin.ts`:
  Example:
  ```typescript
  app.get("/admin", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    // ...
  });
  ```

- [ ] **Step 3.3: Implement GET /admin/login and Auth / Session APIs**
  Add routes:
  * `GET /admin/login` (serves index.html publicly)
  * `GET /admin/api/auth-status` (checks session, returns JSON)
  * `POST /admin/api/login` (performs DB query, password hashing validation, inserts session, sets cookie header)
  * `POST /admin/api/logout` (deletes session token, deletes cookie header)

- [ ] **Step 3.4: Commit the backend auth changes**
  Run: `git add middleware/src/handlers/admin.ts && git commit -m "feat(api): implement database session routes and checkAuth middleware"`

---

### Task 4: UI Login Views & SPA Router Integration

**Files:**
- Modify: `middleware/src/public/index.html`
- Test: `npm run build` in `/middleware` to compile assets.

- [ ] **Step 4.1: Embed Login SPA Panel in index.html**
  Add `#view-login` view right inside `main-container`:
  ```html
  <!-- View 0: Login View -->
  <section id="view-login" class="view">
    <div style="display:flex; justify-content:center; align-items:center; min-height:60vh;">
      <div class="panel" style="width: 420px; padding: 2.5rem; text-align: center; border: 1px solid var(--border-color);">
        <h3 class="panel-title" style="justify-content: center; margin-bottom: 2rem;">Omnichannel Portal</h3>
        <form id="login-form" onsubmit="handleLogin(event)">
          <div class="form-group" style="text-align: left;">
            <label for="login-username">Usuário</label>
            <input type="text" id="login-username" class="form-control" placeholder="Usuário" required>
          </div>
          <div class="form-group" style="text-align: left; margin-bottom: 2rem;">
            <label for="login-password">Senha</label>
            <input type="password" id="login-password" class="form-control" placeholder="Senha" required>
          </div>
          <button type="submit" id="btn-login-submit" class="btn-submit">Entrar</button>
        </form>
      </div>
    </div>
  </section>
  ```

- [ ] **Step 4.2: Implement Auth Router logic in script block**
  Add `checkAuthenticationStatus` on load and implement login/logout form submit handlers:
  * Check `/admin/api/auth-status` on startup. If unauthenticated, toggle `view-login` view active. If authenticated, call `resolveRoute()` to show dashboards.
  * Submit login details to `/admin/api/login`.
  * Add a Logout button in the header calling `/admin/api/logout`.

- [ ] **Step 4.3: Commit visual updates**
  Run: `git add middleware/src/public/index.html && git commit -m "feat(ui): add visual login card, session check, and SPA routing hooks"`

---

### Task 5: Playwright Auth Integration

**Files:**
- Modify: `onboarding/tests/15-admin-portal.spec.ts`
- Test: Run Playwright suite and verify all tests pass.

- [ ] **Step 5.1: Update Mock DB and Mock APIs to intercept auth**
  Update `mockDb.query` in the spec file to support querying `users` and `sessions`:
  * Returns user records for matching logins.
  * Simulates sessions inserts, selects, and status checks.

- [ ] **Step 5.2: Replace Basic Auth tests with Cookie-based validation**
  Implement the login helpers and add Playwright E2E cookies to testing context:
  ```typescript
  // Before navigating:
  const token = 'mock-session-token-99';
  await context.addCookies([{
    name: 'admin_session',
    value: token,
    domain: '127.0.0.1',
    path: '/'
  }]);
  ```

- [ ] **Step 5.3: Run full verification suite**
  Run: `npx playwright test tests/15-admin-portal.spec.ts`
  Expected: All test cases pass successfully.

- [ ] **Step 5.4: Commit tests and final documentation**
  Run: `git add onboarding/tests/15-admin-portal.spec.ts && git commit -m "test: migrate admin tests to database cookie sessions"`
