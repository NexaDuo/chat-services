# Client Triage Agent (Dify + Middleware + Chatwoot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create an automated triage agent in Dify that collects client info (Name, Phone, CPF, Address) and persists it in Chatwoot via a secure Middleware.

**Architecture:** 
1. **Dify Chatflow**: Orchestrates the conversation and collects data.
2. **Middleware**: Exposes a `/tools/chatwoot/update-contact` endpoint with validation and multi-tenant isolation.
3. **Chatwoot**: Stores the contact data in the core CRM/Database.

**Tech Stack:** Dify (Chatflow), Node.js/Fastify (Middleware), Chatwoot (CRM/DB), Zod (Validation), OpenAPI (Integration).

---

### Task 1: Extend ChatwootClient in Middleware

**Files:**
- Modify: `middleware/src/chatwoot.ts`

- [ ] **Step 1: Add `updateContact` method to `ChatwootClient`**

```typescript
  async updateContact(params: {
    accountId: number | string;
    contactId: number | string;
    fields: {
      name?: string;
      email?: string;
      phone_number?: string;
      custom_attributes?: Record<string, unknown>;
    };
  }): Promise<void> {
    const url = `/api/v1/accounts/${params.accountId}/contacts/${params.contactId}`;
    await this.http.put(url, params.fields);
    this.logger.debug(
      {
        accountId: params.accountId,
        contactId: params.contactId,
        fieldsChanged: Object.keys(params.fields),
      },
      "chatwoot: contact updated",
    );
  }
```

- [ ] **Step 2: Verify compilation**

Run: `npm run build` in `middleware` directory.
Expected: PASS

---

### Task 2: Implement Tool Handler in Middleware

**Files:**
- Create: `middleware/src/handlers/tools-chatwoot.ts`
- Modify: `middleware/src/index.ts`
- Modify: `middleware/src/metrics.ts`

- [ ] **Step 1: Define metrics for tool calls**

In `middleware/src/metrics.ts`:
```typescript
    toolCallsTotal: new Counter({
      name: "middleware_tool_calls_total",
      help: "Tool proxy calls by tenant and outcome",
      labelNames: ["account_id", "tool", "result"],
    }),
```

- [ ] **Step 2: Create the handler**

In `middleware/src/handlers/tools-chatwoot.ts`:
```typescript
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Config } from "../config.js";
import type { Metrics } from "../metrics.js";
import type { ChatwootClient } from "../chatwoot.js";
import { resolveTenant } from "../config.js";

const UpdateContactBody = z.object({
  account_id: z.union([z.string(), z.number()]),
  contact_id: z.union([z.string(), z.number()]),
  fields: z.object({
    name: z.string().trim().min(1).max(255).optional(),
    email: z.string().email().max(255).optional(),
    phone_number: z.string().trim().min(5).max(32).optional(),
    custom_attributes: z.record(z.string(), z.union([
      z.string(), z.number(), z.boolean(), z.null()
    ])).optional(),
  }).refine((v) => Object.keys(v).length > 0, {
    message: "fields must contain at least one updatable property",
  }),
}).strict();

export async function registerToolsChatwootRoute(
  app: FastifyInstance,
  config: Config,
  metrics: Metrics,
  chatwoot: ChatwootClient,
): Promise<void> {
  app.post("/tools/chatwoot/update-contact", async (req, reply) => {
    // 1. Auth check
    const secret = req.headers["x-tool-secret"] || req.headers["x-handoff-secret"];
    if (secret !== config.handoffSharedSecret) {
      return reply.code(401).send({ error: "unauthorized" });
    }

    // 2. Validate body
    const result = UpdateContactBody.safeParse(req.body);
    if (!result.success) {
      return reply.code(400).send({ error: "invalid_payload", issues: result.error.issues });
    }
    const { account_id, contact_id, fields } = result.data;

    // 3. Resolve tenant
    const tenant = resolveTenant(config, account_id);
    if (!tenant) {
      metrics.toolCallsTotal.inc({ account_id: String(account_id), tool: "update_contact", result: "error_unknown_tenant" });
      return reply.code(403).send({ error: "unknown_tenant" });
    }

    try {
      await chatwoot.updateContact({
        accountId: account_id,
        contactId: contact_id,
        fields
      });
      metrics.toolCallsTotal.inc({ account_id: String(account_id), tool: "update_contact", result: "ok" });
      req.log.info({ accountId: account_id, contactId: contact_id, fieldsChanged: Object.keys(fields) }, "tool: update_contact ok");
      return { ok: true };
    } catch (err) {
      metrics.toolCallsTotal.inc({ account_id: String(account_id), tool: "update_contact", result: "error_chatwoot" });
      req.log.error({ err, accountId: account_id, contactId: contact_id }, "tool: update_contact failed");
      return reply.code(500).send({ error: "chatwoot_error" });
    }
  });
}
```

- [ ] **Step 3: Register the route in `index.ts`**

```typescript
import { registerToolsChatwootRoute } from "./handlers/tools-chatwoot.js";
// ...
await registerToolsChatwootRoute(app, config, metrics, chatwoot);
```

---

### Task 3: Create OpenAPI Specification for Dify

**Files:**
- Create: `dify-apps/tools/chatwoot-proxy.v1.yaml`

- [ ] **Step 1: Write the OpenAPI YAML**

```yaml
openapi: 3.0.1
info:
  title: NexaDuo Tool Proxy
  description: Secure proxy for Chatwoot operations from Dify agents.
  version: 1.0.0
servers:
  - url: https://api.nexaduo.com # Replace with actual middleware URL
paths:
  /tools/chatwoot/update-contact:
    post:
      operationId: updateContact
      summary: Updates contact information in Chatwoot.
      security:
        - ApiKeyAuth: []
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/UpdateContactRequest'
      responses:
        '200':
          description: OK
          content:
            application/json:
              schema:
                type: object
                properties:
                  ok:
                    type: boolean
        '400':
          description: Invalid payload
        '401':
          description: Unauthorized
        '403':
          description: Unknown tenant
components:
  securitySchemes:
    ApiKeyAuth:
      type: apiKey
      in: header
      name: x-tool-secret
  schemas:
    UpdateContactRequest:
      type: object
      required:
        - account_id
        - contact_id
        - fields
      properties:
        account_id:
          oneOf:
            - type: string
            - type: number
        contact_id:
          oneOf:
            - type: string
            - type: number
        fields:
          type: object
          properties:
            name:
              type: string
            email:
              type: string
            phone_number:
              type: string
            custom_attributes:
              type: object
              additionalProperties:
                oneOf:
                  - type: string
                  - type: number
                  - type: boolean
                  - type: null
```

---

### Task 4: Dify Chatflow Configuration (Guide)

- [ ] **Step 1: Create a new Chatflow in Dify**
- [ ] **Step 2: Add Variable Collection Nodes** for Name, Phone, CPF, and Address.
- [ ] **Step 3: Register Custom Tool**: Use the YAML from Task 3.
- [ ] **Step 4: Use Tool Node**: 
    - Input `account_id` and `contact_id` (usually passed from Chatwoot via URL parameters or conversation variables).
    - Map collected variables to `fields.name`, `fields.phone_number`, and `fields.custom_attributes.cpf`, `fields.custom_attributes.address`.

---
