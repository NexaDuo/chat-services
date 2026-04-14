# Coding Conventions

**Analysis Date:** 2026-04-14

## Naming Patterns

**Files:**
- TypeScript: Kebab-case (e.g., `chatwoot-webhook.ts`, `self-healing-agent.ts`).
- Terraform: Kebab-case (e.g., `cloudflare-tunnel.tf`).
- Shell scripts: Kebab-case (e.g., `create-tenant.sh`).
- Project Phases: `[XX]-[phase-name]` (e.g., `01-foundation`).

**Functions:**
- CamelCase for TypeScript (e.g., `resolveTenant`, `handleWebhook`).

**Variables:**
- CamelCase for internal logic.
- UPPER_SNAKE_CASE for environment variables.

**Types:**
- PascalCase for TypeScript interfaces and types (e.g., `TenantConfig`, `ChatwootMessage`).

## Code Style

**Formatting:**
- Prettier (inferred from common Node.js patterns in the repo).
- Standard TypeScript indentation (2 spaces).

**Linting:**
- ESLint (inferred).

## Import Organization

**Order:**
1. Built-in modules (e.g., `path`, `fs`).
2. Third-party packages (e.g., `fastify`, `zod`).
3. Local modules (e.g., `./config`, `../utils`).

**Path Aliases:**
- Not detected.

## Error Handling

**Patterns:**
- Try-catch blocks in Fastify handlers.
- Error logs via `pino`.
- Middleware posts private notes to Chatwoot for user-facing errors.

## Logging

**Framework:** Pino (standard for high-performance Node.js).

**Patterns:**
- Log error events with context.
- Log incoming webhook payloads for debugging.

## Comments

**When to Comment:**
- Complexity: Explain why a specific transformation is needed (e.g., Dify to Chatwoot mapping).
- Planning: Use `# Phase [X]` comments in Terraform or scripts.

**JSDoc/TSDoc:**
- Minimal usage observed; primarily focused on type safety via TypeScript.

## Function Design

**Size:** Small, focused handlers and API wrappers.

**Parameters:** Prefer object destructuring for more than 2 parameters.

## Module Design

**Exports:** Named exports preferred over default exports for better tree-shaking and clarity.

**Barrel Files:** Used sparingly (e.g., `handlers/config.ts`).

---

*Convention analysis: 2026-04-14*
