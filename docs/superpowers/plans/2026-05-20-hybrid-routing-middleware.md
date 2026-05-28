# Hybrid Routing Middleware Resolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update the `/resolve-tenant` endpoint in the Middleware to return infrastructure overrides (`infraType`, `chatwootUrl`, `difyUrl`) from the database.

**Architecture:** 
1. Update the SQL query in `middleware/src/handlers/tenant.ts` to fetch new columns.
2. Update the response structure to include `infraType` and `overrides`.
3. Set up a minimal test environment to verify the changes via TDD.

**Tech Stack:** Node.js, Fastify, pg (node-postgres), Vitest (for testing).

---

### Task 1: Setup Minimal Test Environment

**Files:**
- Modify: `middleware/package.json`
- Create: `middleware/src/handlers/tenant.test.ts`

- [ ] **Step 1: Install Vitest**

Run: `cd middleware && npm install -D vitest`

- [ ] **Step 2: Add test script to package.json**

Modify `middleware/package.json`:
```json
"scripts": {
  ...
  "test": "vitest run"
}
```

- [ ] **Step 3: Create a failing test for the new resolver response**

Create `middleware/src/handlers/tenant.test.ts`:
```typescript
import { test, expect, vi, beforeEach } from 'vitest';
import { registerTenantRoute } from './tenant.js';
import Fastify from 'fastify';

test('resolve-tenant returns infra overrides', async () => {
  const app = Fastify();
  const mockConfig = { handoff: { sharedSecret: 'test-secret' } };
  const mockPool = {
    query: vi.fn().mockResolvedValue({
      rows: [{
        chatwoot_account_id: 123,
        infra_type: 'dedicated',
        chatwoot_url: 'https://cw.example.com',
        dify_url: 'https://dify.example.com'
      }]
    })
  };

  await registerTenantRoute(app as any, mockConfig as any, mockPool as any);

  const response = await app.inject({
    method: 'GET',
    url: '/resolve-tenant',
    query: { subdomain: 'test' },
    headers: { authorization: 'Bearer test-secret' }
  });

  expect(response.statusCode).toBe(200);
  const body = JSON.parse(response.payload);
  expect(body).toEqual({
    subdomain: 'test',
    accountId: 123,
    infraType: 'dedicated',
    overrides: {
      chatwootUrl: 'https://cw.example.com',
      difyUrl: 'https://dify.example.com'
    }
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd middleware && npm test`
Expected: FAIL (missing fields in response)

- [ ] **Step 5: Commit test setup**

```bash
git add middleware/package.json middleware/src/handlers/tenant.test.ts
git commit -m "test(middleware): add failing test for hybrid routing resolver"
```

---

### Task 2: Update Resolver Implementation

**Files:**
- Modify: `middleware/src/handlers/tenant.ts`

- [ ] **Step 1: Update SQL query and response body**

Modify `middleware/src/handlers/tenant.ts`:
Update the `SELECT` query and the `reply.send` block.

```typescript
      const result = await pool.query(
        "SELECT chatwoot_account_id, infra_type, chatwoot_url, dify_url FROM tenants WHERE subdomain = $1",
        [subdomain]
      );
      
      if (result.rows.length === 0) {
        return reply.code(404).send({ error: "tenant_not_found" });
      }

      const row = result.rows[0];
      return reply.code(200).send({
        subdomain,
        accountId: row.chatwoot_account_id,
        infraType: row.infra_type,
        overrides: {
          chatwootUrl: row.chatwoot_url,
          difyUrl: row.dify_url
        }
      });
```

- [ ] **Step 2: Run test to verify it passes**

Run: `cd middleware && npm test`
Expected: PASS

- [ ] **Step 3: Commit implementation**

```bash
git add middleware/src/handlers/tenant.ts
git commit -m "feat(middleware): include infra overrides in tenant resolution"
```
