import { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import pg from "pg";
import defaultAxios from "axios";
import { AppConfig } from "../config.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const htmlPath = path.resolve(__dirname, "../public/index.html");

export async function registerAdminRoutes(
  app: FastifyInstance,
  config: AppConfig,
  pool: pg.Pool,
  customHttpClient?: any,
): Promise<void> {
  const axios = (customHttpClient || defaultAxios) as typeof defaultAxios;
  const checkAuth = (request: FastifyRequest, reply: FastifyReply): boolean => {
    const authHeader = request.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Basic ")) {
      void reply.code(401).header("WWW-Authenticate", 'Basic realm="Admin Portal"').send({ error: "unauthorized" });
      return false;
    }

    try {
      const credentials = Buffer.from(authHeader.split(" ")[1], "base64").toString("ascii");
      const [username, password] = credentials.split(":");
      const expectedPassword = config.adminPassword || config.handoff.sharedSecret;

      if (username !== "admin" || password !== expectedPassword) {
        void reply.code(401).header("WWW-Authenticate", 'Basic realm="Admin Portal"').send({ error: "unauthorized" });
        return false;
      }
    } catch {
      void reply.code(401).header("WWW-Authenticate", 'Basic realm="Admin Portal"').send({ error: "unauthorized" });
      return false;
    }

    return true;
  };

  // GET /admin
  app.get("/admin", async (request, reply) => {
    if (!checkAuth(request, reply)) return;
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
    if (!checkAuth(request, reply)) return;
    try {
      const html = await fs.readFile(htmlPath, "utf-8");
      return reply.code(200).type("text/html").send(html);
    } catch (err) {
      app.log.error({ err, htmlPath }, "Failed to read index.html");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // GET /admin/api/tenants
  app.get("/admin/api/tenants", async (request, reply) => {
    if (!checkAuth(request, reply)) return;
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
    if (!checkAuth(request, reply)) return;
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

  // POST /admin/api/tenants/:tenantSlug/provision
  app.post("/admin/api/tenants/:tenantSlug/provision", async (request, reply) => {
    if (!checkAuth(request, reply)) return;

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

      // 6. Create Instagram instance in Evolution API
      const instanceName = `${subdomain}-instagram`;
      try {
        if (config.evolution.apiKey) {
          const evoBaseUrl = config.evolution.baseUrl;
          await axios.post(
            `${evoBaseUrl}/instance/create`,
            {
              instanceName,
              token: "",
              integration: "instagram",
              qrcode: false
            },
            { headers: { apikey: config.evolution.apiKey } }
          );

          await axios.post(
            `${evoBaseUrl}/chatwoot/set/${instanceName}`,
            {
              enabled: true,
              accountId: String(accountId),
              url: chatwootUrl,
              token: config.chatwoot.apiToken,
              importMessages: true,
              syncContact: true
            },
            { headers: { apikey: config.evolution.apiKey } }
          );
        }
      } catch (evoErr: any) {
        app.log.error({ evoErr }, "Evolution API provisioning failed. Rolling back DB and Chatwoot.");
        await pool.query("DELETE FROM tenants WHERE slug = $1", [subdomain]).catch(err => app.log.error({ err }));
        await axios.delete(
          `${chatwootUrl}/platform/api/v1/accounts/${accountId}`,
          { headers: { api_access_token: platformToken } }
        ).catch(err => app.log.error({ err }, "Failed to rollback Chatwoot account"));
        throw evoErr;
      }

      return reply.code(201).send({
        status: "success",
        accountId: String(accountId),
        instanceName,
        message: "Account created and instance initialized under selected tenant."
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
    if (!checkAuth(request, reply)) return;
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

      // 3. Fetch Evolution API instances
      let evolutionInstances: any[] = [];
      try {
        if (config.evolution.apiKey) {
          const evoBaseUrl = config.evolution.baseUrl;
          const evoResp = await axios.get(
            `${evoBaseUrl}/instance/fetchInstances`,
            { headers: { apikey: config.evolution.apiKey } }
          );
          evolutionInstances = Array.isArray(evoResp.data) ? evoResp.data : (evoResp.data?.instances || []);
        }
      } catch (err) {
        app.log.error({ err, tenantSlug }, "Failed to fetch Evolution API instances");
      }

      // 4. Fetch Dify Apps from database
      const difyApps = await fetchDifyApps(config, pool);

      // 5. Fetch currently mapped tenants in our middleware db
      const mappedResult = await pool.query(
        "SELECT subdomain, chatwoot_account_id, dify_api_key FROM tenants WHERE chatwoot_url = $1",
        [chatwootUrl]
      );
      const mappedRows = mappedResult.rows;
      const mappedAccountIds = new Set(mappedRows.map(r => String(r.chatwoot_account_id)));
      const mappedSubdomains = new Set(mappedRows.map(r => String(r.subdomain)));
      const mappedDifyKeys = new Set(mappedRows.map(r => String(r.dify_api_key)));

      // 6. Cross-reference and format the list
      const formattedCwAccounts = chatwootAccounts.map((acc: any) => ({
        id: String(acc.id),
        name: acc.name,
        mapped: mappedAccountIds.has(String(acc.id))
      }));

      const formattedEvoInstances = evolutionInstances.map((inst: any) => {
        const name = inst.name || inst.instanceName;
        let isMapped = false;
        for (const sub of mappedSubdomains) {
          if (name === `${sub}-instagram`) {
            isMapped = true;
            break;
          }
        }
        return {
          instanceName: name,
          status: inst.status || inst.connectionState || "disconnected",
          mapped: isMapped
        };
      });

      const formattedDifyApps = difyApps.map((app: any) => ({
        id: app.id,
        name: app.name,
        mode: app.mode,
        apiKey: app.apiKey,
        mapped: app.apiKey ? mappedDifyKeys.has(String(app.apiKey)) : false
      }));

      return reply.code(200).send({
        chatwootAccounts: formattedCwAccounts,
        evolutionInstances: formattedEvoInstances,
        difyApps: formattedDifyApps
      });
    } catch (err) {
      app.log.error({ err, tenantSlug }, "Failed during discovery");
      return reply.code(500).send({ error: "internal_server_error" });
    }
  });

  // POST /admin/api/tenants/:tenantSlug/import
  app.post("/admin/api/tenants/:tenantSlug/import", async (request, reply) => {
    if (!checkAuth(request, reply)) return;
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

      // 4. Connect/Configure Instagram instance in Evolution API
      const instanceName = `${subdomain}-instagram`;
      try {
        if (config.evolution.apiKey) {
          const evoBaseUrl = config.evolution.baseUrl;
          
          let exists = false;
          try {
            const listResp = await axios.get(
              `${evoBaseUrl}/instance/fetchInstances`,
              { headers: { apikey: config.evolution.apiKey } }
            );
            const instances = Array.isArray(listResp.data) ? listResp.data : (listResp.data?.instances || []);
            exists = instances.some((inst: any) => (inst.name || inst.instanceName) === instanceName);
          } catch (listErr) {
            app.log.warn({ listErr }, "Failed to fetch existing instances to check for duplicates");
          }

          if (!exists) {
            await axios.post(
              `${evoBaseUrl}/instance/create`,
              {
                instanceName,
                token: "",
                integration: "instagram",
                qrcode: false
              },
              { headers: { apikey: config.evolution.apiKey } }
            );
          }

          await axios.post(
            `${evoBaseUrl}/chatwoot/set/${instanceName}`,
            {
              enabled: true,
              accountId: chatwootAccountId,
              url: chatwootUrl,
              token: config.chatwoot.apiToken,
              importMessages: true,
              syncContact: true
            },
            { headers: { apikey: config.evolution.apiKey } }
          );
        }
      } catch (evoErr: any) {
        app.log.error({ evoErr }, "Evolution API import sync failed. Rolling back DB mapping.");
        await pool.query("DELETE FROM tenants WHERE subdomain = $1", [subdomain]).catch(err => app.log.error({ err }));
        throw evoErr;
      }

      return reply.code(201).send({
        status: "success",
        accountId: chatwootAccountId,
        instanceName,
        message: "Account imported and synchronized successfully."
      });
    } catch (err: any) {
      app.log.error({ err }, "Failed to import account");
      const status = err.response?.status || 500;
      const errorMsg = err.response?.data?.message || err.message || "internal_server_error";
      return reply.code(status >= 400 && status < 600 ? status : 500).send({ error: errorMsg });
    }
  });

  // GET /admin/api/instances/:name/status
  app.get("/admin/api/instances/:name/status", async (request, reply) => {
    if (!checkAuth(request, reply)) return;
    const { name } = request.params as { name: string };
    try {
      if (!config.evolution.apiKey) {
        return reply.code(200).send({ instanceName: name, connectionState: "offline" });
      }
      const response = await axios.get(
        `${config.evolution.baseUrl}/instance/connectionState/${name}`,
        { headers: { apikey: config.evolution.apiKey } }
      );
      return reply.code(200).send({
        instanceName: name,
        connectionState: response.data.instance?.state || "unknown"
      });
    } catch (err: any) {
      app.log.error({ err, name }, "Failed to fetch instance connection state");
      return reply.code(200).send({ instanceName: name, connectionState: "disconnected" });
    }
  });
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
