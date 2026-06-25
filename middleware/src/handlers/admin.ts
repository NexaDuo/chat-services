import { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fs from "fs/promises";
import fsSync from "fs";
import path from "path";
import { fileURLToPath } from "url";
import staticPlugin from "@fastify/static";
import pg from "pg";
import defaultAxios from "axios";
import crypto from "crypto";
import { AppConfig } from "../config.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const htmlPath = path.resolve(__dirname, "../public/index.html");
// Built React SPA (Vite output): dist/public/app/{index.html,assets/*}.
const appDir = path.resolve(__dirname, "../public/app");

export async function registerAdminRoutes(
  app: FastifyInstance,
  config: AppConfig,
  pool: pg.Pool,
  customHttpClient?: any,
): Promise<void> {
  const axios = (customHttpClient || defaultAxios) as typeof defaultAxios;
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

  // Serve the React admin SPA (Vite build) under /admin/app. Assets are public
  // (the data they fetch is behind the cookie-authed API); the HTML entry is
  // auth-gated like the legacy portal. existsSync-guarded so `npm run dev`
  // (no build output) does not crash on a missing directory.
  const assetsDir = path.join(appDir, "assets");
  if (fsSync.existsSync(assetsDir)) {
    await app.register(staticPlugin, {
      root: assetsDir,
      prefix: "/admin/app/assets/",
      decorateReply: false,
    });
  }

  const serveAdminApp = async (request: FastifyRequest, reply: FastifyReply) => {
    if (!(await checkAuth(request, reply))) return;
    const appHtml = path.join(appDir, "index.html");
    try {
      const html = await fs.readFile(appHtml, "utf-8");
      return reply.code(200).type("text/html").send(html);
    } catch (err) {
      app.log.error({ err, appHtml }, "Failed to read admin-ui index.html (build missing?)");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  };
  app.get("/admin/app", serveAdminApp);
  app.get("/admin/app/", serveAdminApp);

  // GET /admin/login
  app.get("/admin/login", async (_request, reply) => {
    try {
      const html = await fs.readFile(htmlPath, "utf-8");
      return reply.code(200).type("text/html").send(html);
    } catch (err) {
      app.log.error({ err, htmlPath }, "Failed to read index.html");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin
  app.get("/admin", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    try {
      const html = await fs.readFile(htmlPath, "utf-8");
      return reply.code(200).type("text/html").send(html);
    } catch (err) {
      app.log.error({ err, htmlPath }, "Failed to read index.html");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin/:tenantSlug
  app.get("/admin/:tenantSlug", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    try {
      const html = await fs.readFile(htmlPath, "utf-8");
      return reply.code(200).type("text/html").send(html);
    } catch (err) {
      app.log.error({ err, htmlPath }, "Failed to read index.html");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin/api/auth-status
  app.get("/admin/api/auth-status", async (request, reply) => {
    const cookieHeader = request.headers.cookie || "";
    const match = cookieHeader.match(/admin_session=([^;]+)/);
    const token = match ? match[1] : null;

    if (!token) {
      return reply.code(200).send({ authenticated: false });
    }

    try {
      const result = await pool.query(
        `SELECT u.username, u.role
         FROM sessions s
         JOIN users u ON s.user_id = u.id
         WHERE s.token = $1 AND s.expires_at > CURRENT_TIMESTAMP
         LIMIT 1`,
        [token]
      );

      if (result.rows.length === 0) {
        return reply.code(200).send({ authenticated: false });
      }

      return reply.code(200).send({
        authenticated: true,
        username: result.rows[0].username,
        role: result.rows[0].role
      });
    } catch (err) {
      app.log.error({ err }, "Database session check failed during auth-status");
      return reply.code(200).send({ authenticated: false });
    }
  });

  // POST /admin/api/login
  app.post("/admin/api/login", async (request, reply) => {
    const { username, password } = request.body as { username?: string; password?: string };
    if (!username || !password) {
      return reply.code(400).send({ error: "missing_fields" });
    }

    try {
      const pwdHash = crypto.createHash("sha256").update(password).digest("hex");
      const userRes = await pool.query(
        "SELECT id, password_hash, role FROM users WHERE username = $1 LIMIT 1",
        [username]
      );

      if (userRes.rows.length === 0 || userRes.rows[0].password_hash !== pwdHash) {
        return reply.code(401).send({ error: "invalid_credentials" });
      }

      const user = userRes.rows[0];
      const token = crypto.randomBytes(32).toString("hex");
      const expiresAt = new Date(Date.now() + 24 * 60 * 60 * 1000); // 24 hours

      await pool.query(
        "INSERT INTO sessions (user_id, token, expires_at) VALUES ($1, $2, $3)",
        [user.id, token, expiresAt]
      );

      void reply.header(
        "Set-Cookie",
        `admin_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=86400`
      );

      return reply.code(200).send({
        status: "success",
        username,
        role: user.role
      });
    } catch (err) {
      app.log.error({ err }, "Login failed");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // POST /admin/api/logout
  app.post("/admin/api/logout", async (request, reply) => {
    const cookieHeader = request.headers.cookie || "";
    const match = cookieHeader.match(/admin_session=([^;]+)/);
    const token = match ? match[1] : null;

    if (token) {
      try {
        await pool.query("DELETE FROM sessions WHERE token = $1", [token]);
      } catch (err) {
        app.log.error({ err }, "Failed to delete session token from database during logout");
      }
    }

    void reply.header(
      "Set-Cookie",
      "admin_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    );

    return reply.code(200).send({ status: "success" });
  });

  // GET /admin/api/tenants
  app.get("/admin/api/tenants", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    try {
      const result = await pool.query(
        "SELECT DISTINCT ON (slug) slug, name, chatwoot_url, dify_url FROM tenants WHERE status = 'active' AND chatwoot_account_id = '1'"
      );
      const list = result.rows.map(row => ({
        slug: row.slug,
        name: row.name,
        chatwootUrl: row.chatwoot_url,
        difyUrl: row.dify_url
      }));
      return reply.code(200).send(list);
    } catch (err) {
      app.log.error({ err }, "Failed to fetch physical tenants");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin/api/tenants/:tenantSlug/accounts
  app.get("/admin/api/tenants/:tenantSlug/accounts", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    const { tenantSlug } = request.params as { tenantSlug: string };
    try {
      const parentRes = await pool.query(
        "SELECT chatwoot_url FROM tenants WHERE slug = $1 AND chatwoot_account_id = '1' LIMIT 1",
        [tenantSlug]
      );
      if (parentRes.rows.length === 0) {
        return reply.code(404).send({ error: "parent_tenant_not_found" });
      }
      const chatwootUrl = parentRes.rows[0].chatwoot_url;

      const result = await pool.query(
        "SELECT slug, subdomain, name, chatwoot_account_id, status, dify_app_type FROM tenants WHERE chatwoot_url = $1 AND chatwoot_account_id != '1' ORDER BY created_at DESC",
        [chatwootUrl]
      );
      const accounts = result.rows.map(row => ({
        slug: row.slug,
        subdomain: row.subdomain,
        name: row.name,
        chatwootAccountId: row.chatwoot_account_id,
        status: row.status,
        difyAppType: row.dify_app_type
      }));
      return reply.code(200).send(accounts);
    } catch (err) {
      app.log.error({ err, tenantSlug }, "Failed to fetch client accounts");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin/api/accounts — all tenant rows with their Dify routing config.
  // Never returns the key itself, only `difyApiKeySet`. Powers the React
  // "Roteamento de Dify por conta" screen (/admin/app).
  app.get("/admin/api/accounts", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    try {
      const result = await pool.query(
        `SELECT slug, subdomain, name, chatwoot_account_id, status, dify_app_type,
                chatwoot_url, dify_url, dify_api_key
           FROM tenants
          ORDER BY chatwoot_account_id, created_at DESC`
      );

      // Best-effort: resolve each tenant's Dify app (id + name) by matching its
      // API key against the Dify workspace, so the UI can deep-link straight to
      // the app ("space"). Degrades to just the workspace link when Dify is
      // unreachable. The key is used only server-side for the match, never sent.
      let appsByKey = new Map<string, { id: string; name: string }>();
      try {
        const difyApps = await fetchDifyApps(config, pool);
        appsByKey = new Map(
          difyApps
            .filter((a: any) => a.apiKey)
            .map((a: any) => [String(a.apiKey), { id: String(a.id), name: a.name }])
        );
      } catch (err) {
        app.log.warn({ err }, "Could not resolve Dify apps for account links");
      }

      const accounts = result.rows.map(row => {
        const matched = row.dify_api_key ? appsByKey.get(String(row.dify_api_key)) : undefined;
        return {
          slug: row.slug,
          subdomain: row.subdomain,
          name: row.name,
          chatwootAccountId: row.chatwoot_account_id,
          status: row.status,
          difyAppType: row.dify_app_type,
          chatwootUrl: row.chatwoot_url,
          difyUrl: row.dify_url, // Dify workspace ("space") link
          difyAppId: matched ? matched.id : null,
          difyAppName: matched ? matched.name : null,
          difyApiKeySet: !!(row.dify_api_key && row.dify_api_key !== ""),
        };
      });
      return reply.code(200).send(accounts);
    } catch (err) {
      app.log.error({ err }, "Failed to fetch accounts for dify config");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // PUT /admin/api/accounts/:slug/dify — update an existing account's Dify
  // routing (app type + optional key). The key is preserved when the body omits
  // it (COALESCE), mirroring the seeder so a blank field never wipes a set key.
  // The response never echoes the key.
  app.put("/admin/api/accounts/:slug/dify", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    const { slug } = request.params as { slug: string };
    const { difyAppType, difyApiKey } = (request.body || {}) as {
      difyAppType?: string;
      difyApiKey?: string;
    };
    if (difyAppType !== "agent" && difyAppType !== "chatflow") {
      return reply.code(400).send({ error: "invalid_dify_app_type" });
    }
    const key =
      typeof difyApiKey === "string" && difyApiKey.trim() ? difyApiKey.trim() : null;
    try {
      const result = await pool.query(
        `UPDATE tenants
            SET dify_app_type = $1,
                dify_api_key = COALESCE($2, dify_api_key),
                updated_at = CURRENT_TIMESTAMP
          WHERE slug = $3`,
        [difyAppType, key, slug]
      );
      if (result.rowCount === 0) {
        return reply.code(404).send({ error: "account_not_found" });
      }
      return reply
        .code(200)
        .send({ status: "success", slug, difyAppType, difyApiKeyUpdated: key !== null });
    } catch (err) {
      app.log.error({ err, slug }, "Failed to update dify config");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // POST /admin/api/tenants/:tenantSlug/provision
  app.post("/admin/api/tenants/:tenantSlug/provision", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;

    const { tenantSlug } = request.params as { tenantSlug: string };
    const { name, email, adminName, subdomain, difyApiKey, difyAppType } = request.body as {
      name: string;
      email: string;
      adminName: string;
      subdomain: string;
      difyApiKey: string;
      difyAppType: string;
    };

    if (!name || !email || !adminName || !subdomain || !difyApiKey || !difyAppType) {
      return reply.code(400).send({ error: "missing_fields" });
    }

    try {
      // 1. Resolve parent URLs
      const tenantRes = await pool.query(
        "SELECT chatwoot_url, dify_url FROM tenants WHERE slug = $1 AND chatwoot_account_id = '1' LIMIT 1",
        [tenantSlug]
      );
      if (tenantRes.rows.length === 0) {
        return reply.code(404).send({ error: "parent_tenant_not_found" });
      }
      const { chatwoot_url: chatwootUrl, dify_url: difyUrl } = tenantRes.rows[0];

      // 2. Call Chatwoot Platform API to create Account
      const platformToken = config.chatwoot.platformToken || config.chatwoot.apiToken;
      const accountResp = await axios.post(
        `${chatwootUrl}/platform/api/v1/accounts`,
        { name },
        { headers: { api_access_token: platformToken } }
      );
      const accountId = accountResp.data.id;

      let userId: number | undefined;
      try {
        // 3. Call Chatwoot Platform API to create User
        const randomPassword = Buffer.from(Math.random().toString()).toString("hex").substring(0, 16);
        const userResp = await axios.post(
          `${chatwootUrl}/platform/api/v1/users`,
          { name: adminName, email, password: randomPassword },
          { headers: { api_access_token: platformToken } }
        );
        userId = userResp.data.id;

        // 4. Link User to Account
        await axios.post(
          `${chatwootUrl}/platform/api/v1/accounts/${accountId}/account_users`,
          { user_id: userId, role: "administrator" },
          { headers: { api_access_token: platformToken } }
        );
      } catch (userErr: any) {
        app.log.error({ userErr }, "Failed to create/link user. Rolling back Chatwoot account.");
        await axios.delete(
          `${chatwootUrl}/platform/api/v1/accounts/${accountId}`,
          { headers: { api_access_token: platformToken } }
        ).catch(err => app.log.error({ err }, "Failed to rollback Chatwoot account"));
        throw userErr;
      }

      // 5. Insert mapping into Postgres DB
      try {
        await pool.query(
          `INSERT INTO tenants (slug, subdomain, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url, dify_api_key, dify_app_type)
           VALUES ($1, $2, $3, $4, 'active', 'shared', $5, $6, $7, $8)`,
          [subdomain, subdomain, name, String(accountId), chatwootUrl, difyUrl, difyApiKey, difyAppType]
        );
      } catch (dbErr: any) {
        app.log.error({ dbErr }, "Database insert failed. Rolling back Chatwoot resources.");
        await axios.delete(
          `${chatwootUrl}/platform/api/v1/accounts/${accountId}`,
          { headers: { api_access_token: platformToken } }
        ).catch(err => app.log.error({ err }, "Failed to rollback Chatwoot account"));
        throw dbErr;
      }

      // Instagram is handled by Chatwoot's native channel (Meta OAuth), not by
      // Evolution (WhatsApp-only) — see GitHub issue #31. Provisioning now ends
      // after creating the Chatwoot account + tenant mapping; no Evolution call.
      return reply.code(201).send({
        status: "success",
        accountId: String(accountId),
        message: "Account created and mapped under selected tenant."
      });
    } catch (err: any) {
      app.log.error({ err }, "Failed to provision account");
      const status = err.response?.status || 500;
      const errorMsg = err.response?.data?.message || err.message || "internal_server_error";
      return reply.code(status >= 400 && status < 600 ? status : 500).send({ error: errorMsg });
    }
  });

  // GET /admin/api/tenants/:tenantSlug/discovery
  app.get("/admin/api/tenants/:tenantSlug/discovery", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    const { tenantSlug } = request.params as { tenantSlug: string };
    try {
      // 1. Resolve parent URLs
      const parentRes = await pool.query(
        "SELECT chatwoot_url FROM tenants WHERE slug = $1 AND chatwoot_account_id = '1' LIMIT 1",
        [tenantSlug]
      );
      if (parentRes.rows.length === 0) {
        return reply.code(404).send({ error: "parent_tenant_not_found" });
      }
      const chatwootUrl = parentRes.rows[0].chatwoot_url;
      const platformToken = config.chatwoot.platformToken || config.chatwoot.apiToken;

      // 2. Fetch Chatwoot accounts from platform API
      let chatwootAccounts: any[] = [];
      try {
        const cwResp = await axios.get(
          `${chatwootUrl}/platform/api/v1/accounts`,
          { headers: { api_access_token: platformToken } }
        );
        chatwootAccounts = Array.isArray(cwResp.data) ? cwResp.data : (cwResp.data?.accounts || []);
      } catch (err) {
        app.log.error({ err, tenantSlug }, "Failed to fetch Chatwoot accounts via Platform API");
      }

      // Evolution instance discovery removed (issue #31): Evolution is
      // WhatsApp-only and the Instagram instance flow never worked.

      // 3. Fetch Dify Apps from database
      const difyApps = await fetchDifyApps(config, pool);

      // 4. Fetch currently mapped tenants in our middleware db
      const mappedResult = await pool.query(
        "SELECT subdomain, chatwoot_account_id, dify_api_key FROM tenants WHERE chatwoot_url = $1",
        [chatwootUrl]
      );
      const mappedRows = mappedResult.rows;
      const mappedAccountIds = new Set(mappedRows.map(r => String(r.chatwoot_account_id)));
      const mappedDifyKeys = new Set(mappedRows.map(r => String(r.dify_api_key)));

      // 5. Cross-reference and format the list
      const formattedCwAccounts = chatwootAccounts.map((acc: any) => ({
        id: String(acc.id),
        name: acc.name,
        mapped: mappedAccountIds.has(String(acc.id))
      }));

      const formattedDifyApps = difyApps.map((app: any) => ({
        id: app.id,
        name: app.name,
        mode: app.mode,
        apiKey: app.apiKey,
        mapped: app.apiKey ? mappedDifyKeys.has(String(app.apiKey)) : false
      }));

      return reply.code(200).send({
        chatwootAccounts: formattedCwAccounts,
        difyApps: formattedDifyApps
      });
    } catch (err) {
      app.log.error({ err, tenantSlug }, "Failed during discovery");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // POST /admin/api/tenants/:tenantSlug/import
  app.post("/admin/api/tenants/:tenantSlug/import", async (request, reply) => {
    if (!(await checkAuth(request, reply))) return;
    const { tenantSlug } = request.params as { tenantSlug: string };
    const { chatwootAccountId, name, subdomain, difyApiKey, difyAppType } = request.body as {
      chatwootAccountId: string;
      name: string;
      subdomain: string;
      difyApiKey: string;
      difyAppType: string;
    };

    if (!chatwootAccountId || !name || !subdomain || !difyApiKey || !difyAppType) {
      return reply.code(400).send({ error: "missing_fields" });
    }

    try {
      // 1. Resolve parent URLs
      const tenantRes = await pool.query(
        "SELECT chatwoot_url, dify_url FROM tenants WHERE slug = $1 AND chatwoot_account_id = '1' LIMIT 1",
        [tenantSlug]
      );
      if (tenantRes.rows.length === 0) {
        return reply.code(404).send({ error: "parent_tenant_not_found" });
      }
      const { chatwoot_url: chatwootUrl, dify_url: difyUrl } = tenantRes.rows[0];

      // 2. Validate availability of subdomain and account ID
      const conflictRes = await pool.query(
        "SELECT slug FROM tenants WHERE subdomain = $1 OR chatwoot_account_id = $2 LIMIT 1",
        [subdomain, chatwootAccountId]
      );
      if (conflictRes.rows.length > 0) {
        return reply.code(409).send({ error: "subdomain_or_account_already_mapped" });
      }

      // 3. Insert mapping into Postgres DB
      await pool.query(
        `INSERT INTO tenants (slug, subdomain, name, chatwoot_account_id, status, infra_type, chatwoot_url, dify_url, dify_api_key, dify_app_type)
         VALUES ($1, $2, $3, $4, 'active', 'shared', $5, $6, $7, $8)`,
        [subdomain, subdomain, name, chatwootAccountId, chatwootUrl, difyUrl, difyApiKey, difyAppType]
      );

      // No Evolution Instagram step (issue #31): Evolution is WhatsApp-only and
      // Instagram uses Chatwoot's native channel. Import ends after the mapping.
      return reply.code(201).send({
        status: "success",
        accountId: chatwootAccountId,
        message: "Account imported and mapped successfully."
      });
    } catch (err: any) {
      app.log.error({ err }, "Failed to import account");
      const status = err.response?.status || 500;
      const errorMsg = err.response?.data?.message || err.message || "internal_server_error";
      return reply.code(status >= 400 && status < 600 ? status : 500).send({ error: errorMsg });
    }
  });

  // (Removed GET /admin/api/instances/:name/status — Evolution Instagram
  // instance status; dead per issue #31.)
}

async function fetchDifyApps(config: AppConfig, pool: pg.Pool): Promise<{ id: string; name: string; mode: string; apiKey: string | null }[]> {
  if (!config.databaseUrl) {
    console.warn("Database URL not configured in config; skipping Dify apps query.");
    return [];
  }
  const difyDbUrl = config.databaseUrl.replace(/\/middleware(\?.*)?$/, "/dify$1");
  const PoolClass = pg.Pool || (pg as any).default?.Pool;
  if (!PoolClass) {
    console.warn("Postgres Pool class not found in pg import.");
    return [];
  }
  const difyPool = new PoolClass({ connectionString: difyDbUrl });
  try {
    let rows: any[] = [];
    try {
      const res = await difyPool.query(`
        SELECT a.id::text, a.name, a.mode, t.token as api_key
        FROM apps a
        LEFT JOIN api_tokens t ON a.id = t.app_id AND t.type = 'app'
        ORDER BY a.created_at DESC
      `);
      rows = res.rows;
    } catch (err: any) {
      if (err.message && err.message.includes('relation "apps" does not exist')) {
        const res = await difyPool.query(`
          SELECT a.id::text, a.name, a.mode, t.token as api_key
          FROM app a
          LEFT JOIN api_tokens t ON a.id = t.app_id AND t.type = 'app'
          ORDER BY a.created_at DESC
        `);
        rows = res.rows;
      } else {
        throw err;
      }
    }
    return rows.map(r => ({
      id: r.id,
      name: r.name,
      mode: r.mode,
      apiKey: r.api_key || null
    }));
  } catch (err) {
    console.warn("Failed to fetch Dify apps from Dify database directly; attempting query fallback on main pool:", err);
    try {
      const res = await pool.query(`
        SELECT a.id::text, a.name, a.mode, t.token as api_key
        FROM apps a
        LEFT JOIN api_tokens t ON a.id = t.app_id AND t.type = 'app'
        ORDER BY a.created_at DESC
      `);
      return res.rows.map((r: any) => ({
        id: r.id,
        name: r.name,
        mode: r.mode,
        apiKey: r.api_key || null
      }));
    } catch (fallbackErr) {
      console.warn("Query fallback failed:", fallbackErr);
      return [];
    }
  } finally {
    await difyPool.end().catch(() => {});
  }
}
