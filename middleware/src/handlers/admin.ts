import { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import pg from "pg";
import axios from "axios";
import { AppConfig } from "../config.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const htmlPath = path.resolve(__dirname, "../public/index.html");

export async function registerAdminRoutes(
  app: FastifyInstance,
  config: AppConfig,
  pool: pg.Pool,
): Promise<void> {
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
