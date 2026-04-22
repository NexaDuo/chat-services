# Phase 04: Automated Provisioning - Research

**Researched:** 2025-01-24
**Domain:** Infrastructure Automation / Tenant Lifecycle
**Confidence:** HIGH

## Summary

Phase 04 focuses on automating the onboarding process for new tenants. The goal is to move from manual configuration to a "single command" provisioning experience. This involves orchestrating multiple APIs (Chatwoot, Dify, Cloudflare) and updating the central `tenants` registry in the Middleware database.

**Primary recommendation:** Develop a TypeScript-based Provisioning CLI that handles API orchestration, coupled with a Terraform-managed Cloudflare DNS configuration that reads from a shared JSON state file.

## User Constraints (from CONTEXT.md)

### Locked Decisions
- **Orchestration Model:** Global Shared Stack. Single Coolify instance on one GCP VM. [VERIFIED: CONTEXT.md]
- **Multi-Tenancy:** Logical isolation via `account_id` (Chatwoot) and `api_key` (Dify). [VERIFIED: CONTEXT.md]
- **Routing:** Path-based on unified subdomains: `chat.nexaduo.com/{tenant}/` and `dify.nexaduo.com/{tenant}`. [VERIFIED: CONTEXT.md]
- **Infrastructure:** All provisioned via Terraform. [VERIFIED: CONTEXT.md]

### the agent's Discretion
- **Provisioning Tooling:** Choice of language/framework for the provisioning script. (Recommendation: TypeScript for consistency with Middleware).
- **DNS Strategy:** Whether to use individual DNS records or wildcards. (Recommendation: Use CNAMEs for specific subdomains if requested, but rely on path-based routing for default).

### Deferred Ideas (OUT OF SCOPE)
- **Docker Resource Limits:** Per-tenant CPU/Memory limits. [CITED: CONTEXT.md]
- **GCP Secret Manager:** Managed secret services. [CITED: CONTEXT.md]

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PROV-01 | Define a standardized tenant configuration schema. | Defined Zod schema and SQL table structure. |
| PROV-02 | Automate DNS record creation for new tenants via Terraform. | Verified Terraform Cloudflare provider `for_each` pattern. |
| PROV-03 | Automate Cloudflare Worker routing table updates. | Verified wildcard routing and Hono `url.hostname` parsing. |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| TypeScript | 5.x | Logic & Scripting | Type safety and consistency with Middleware. [VERIFIED: npm registry] |
| Commander | 12.x | CLI Framework | Industry standard for Node.js CLIs. [VERIFIED: npm registry] |
| Zod | 3.23.x | Validation | Robust schema validation for tenant data. [VERIFIED: codebase] |
| pg | 8.12.x | Database | Official Postgres client for Node.js. [VERIFIED: codebase] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| Axios | 1.7.x | API Requests | Calling Chatwoot/Dify APIs. [VERIFIED: codebase] |
| Cloudflare SDK | 4.x | Cloudflare API | Optional alternative to Terraform for fast updates. [VERIFIED: npm registry] |

**Installation:**
```bash
npm install commander zod pg axios
```

## Architecture Patterns

### Recommended Project Structure
```
provisioning/
├── src/
│   ├── cli.ts            # Entry point
│   ├── schema.ts         # Zod schemas (PROV-01)
│   ├── services/
│   │   ├── chatwoot.ts   # Platform API wrapper
│   │   ├── dify.ts       # Console API wrapper
│   │   └── database.ts   # Middleware DB updates
│   └── utils/
│       └── validation.ts # Health check logic
├── tenants.json          # Shared state for Terraform
└── README.md
```

### Pattern 1: Tenant Configuration Schema (PROV-01)
**What:** A standardized JSON/Zod schema to define a tenant.
**Example:**
```typescript
const TenantSchema = z.object({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  name: z.string(),
  adminEmail: z.string().email(),
  adminName: z.string(),
  features: z.object({
    difyMode: z.enum(['chat', 'agent']).default('chat'),
    customDomain: z.string().optional()
  })
});
```

### Pattern 2: Cloudflare DNS as Code (PROV-02)
**What:** Terraform reads from `tenants.json` to create CNAME records for subdomains.
**Example:**
```hcl
# infrastructure/terraform/modules/cloudflare-dns/main.tf
locals {
  tenants = jsondecode(file("${path.module}/../../../../provisioning/tenants.json"))
}

resource "cloudflare_record" "tenant_subdomains" {
  for_each = { for t in local.tenants : t.slug => t }
  zone_id  = var.zone_id
  name     = "${each.value.slug}.chat"
  content  = "chat.nexaduo.com"
  type     = "CNAME"
  proxied  = true
}
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| API Auth | Custom token storage | .env + Secret Mgmt | Avoid hardcoded tokens in scripts. |
| DB Migrations | Custom SQL scripts | Knex/TypeORM | (Already handled by 01-init.sql for now). |
| DNS Propagation | Custom retry loops | `dig` or DNS libs | Reliability of verification. |

## Common Pitfalls

### Pitfall 1: Dify App IDs
**What goes wrong:** Dify "Service API Keys" are per-app. If the provisioning script doesn't capture the `app_id` or `api_key`, the Middleware cannot route.
**How to avoid:** The script must capture the response from `POST /apps` and store it immediately in the `tenants` table.

### Pitfall 2: Cloudflare Rate Limits
**What goes wrong:** Rapidly creating many DNS records or Worker routes via API can trigger limits.
**How to avoid:** For bulk onboarding, use Terraform which handles dependency ordering and plan/apply cycles.

### Pitfall 3: Chatwoot Account Emails
**What goes wrong:** Chatwoot requires unique emails for admins.
**How to avoid:** Validate email uniqueness against the Chatwoot API before starting the process.

## Code Examples

### Chatwoot Account Creation (Verified Pattern)
```typescript
// Source: https://www.chatwoot.com/docs/product/channels/api/send-messages
const createAccount = async (name: string) => {
  const resp = await axios.post(`${CHATWOOT_URL}/platform/api/v1/accounts`, 
    { name }, 
    { headers: { api_access_token: PLATFORM_TOKEN } }
  );
  return resp.data.id;
};
```

### Dify App Creation (Community Pattern)
```typescript
// Source: Dify Console API (Self-hosted)
const createApp = async (name: string, mode: string) => {
  const resp = await axios.post(`${DIFY_URL}/console/api/apps`, 
    { name, mode: mode === 'agent' ? 'agent-chat' : 'chat' }, 
    { headers: { Authorization: `Bearer ${ADMIN_TOKEN}` } }
  );
  return resp.data.id; // Follow up to get API Key
};
```

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Terraform | DNS Updates | ✓ | 1.14.3 | — |
| Cloudflare | API Access | ✓ | API v4 | — |
| Postgres | DB Updates | ✓ | 16.1 | — |
| Node.js | Scripting | ✓ | 25.8.2 | — |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Vitest (recommended for TS) |
| Quick run command | `npm test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command |
|--------|----------|-----------|-------------------|
| PROV-01 | Schema Validation | Unit | `vitest run tests/schema.test.ts` |
| PROV-02 | DNS Resolution | Integration | `dig +short acme.chat.nexaduo.com` |
| PROV-03 | Edge Routing | E2E | `curl -I https://chat.nexaduo.com/acme/` |

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V4 Access Control | Yes | Use of `X-Tenant-ID` header for isolation. |
| V5 Input Validation | Yes | Zod schema validation for all tenant inputs. |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tenant Impersonation | Spoofing | Middleware verifies `X-Tenant-ID` against DB. |
| Cross-Tenant Access | Information Disclosure | Scoped database queries (e.g. `WHERE account_id = ?`). |

## Sources

### Primary (HIGH confidence)
- `middleware/src/handlers/tenant.ts` - Verified current resolution logic.
- `infrastructure/postgres/01-init.sql` - Verified `tenants` table schema.
- `edge/cloudflare-worker/src/index.ts` - Verified path-based routing.

### Secondary (MEDIUM confidence)
- Dify Console API - Based on community docs for v1.x self-hosted.

## Metadata
**Confidence breakdown:**
- Standard stack: HIGH
- Architecture: HIGH
- Pitfalls: MEDIUM (API quirks)

**Research date:** 2025-01-24
**Valid until:** 2025-02-24
