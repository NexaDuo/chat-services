# Codebase Concerns

**Analysis Date:** 2025-01-24

## Tech Debt

**Single Postgres Instance (SPOF):**
- Issue: All services (Chatwoot, Dify, Evolution, Middleware, Agent) share a single Postgres container.
- Files: `docker-compose.yml`
- Impact: A failure in Postgres takes down the entire stack. Large database operations in one service (like Dify vector indexing) could impact the chat latency.
- Fix approach: Move to a managed Postgres service or separate instances for core components.

**No Automated Tests:**
- Issue: No test suites were found for either the Middleware or the Self-Healing Agent.
- Files: `middleware/`, `agents/self-healing/`
- Impact: Regression risk when modifying core routing logic or Dify/Chatwoot integrations.
- Fix approach: Introduce Vitest or Jest and implement unit tests for handlers and API clients.

## Security Considerations

**Shared Secret Auth:**
- Issue: `HANDOFF_SHARED_SECRET` is the only authentication for handoff and internal config fetching.
- Files: `middleware/src/handlers/handoff.ts`, `agents/self-healing/src/index.ts`
- Current mitigation: Bearer token validation with a shared secret from `.env`.
- Recommendations: Implement proper API keys or OAuth if external integrations are added.

**Postgres Permissions:**
- Issue: Custom services (`middleware`, `self-healing-agent`) use the primary Postgres credentials.
- Files: `docker-compose.yml`
- Current mitigation: None (uses root-level `POSTGRES_USER`).
- Recommendations: Create dedicated Postgres users with limited permissions for each service.

## Performance Bottlenecks

**Loki Polling Interval:**
- Issue: Self-healing agent polls Loki every 5 minutes.
- Files: `agents/self-healing/src/index.ts` (`POLL_INTERVAL_MS`)
- Cause: The agent is a polling-based background loop.
- Improvement path: Switch to a push-based model (e.g., Loki alerts triggering the agent via webhook) for more real-time healing.

**Middleware/Dify Latency:**
- Issue: Chat responses are blocked on Dify completion (for non-streaming).
- Files: `middleware/src/handlers/chatwoot-webhook.ts`
- Cause: Synchronous wait for LLM output.
- Improvement path: Standardize on streaming responses where possible or optimize Dify workflows.

## Fragile Areas

**Tenant Resolution:**
- Issue: `TENANT_MAP` is parsed from a JSON string in environment variables.
- Files: `middleware/src/config.ts`
- Why fragile: Invalid JSON in `.env` will crash the middleware on start. Manual mapping is error-prone.
- Safe modification: Validate JSON schema during startup (partially done with Zod).
- Test coverage: Gaps.

## Test Coverage Gaps

**Middleware Handlers:**
- What's not tested: The core `/webhooks/chatwoot` logic that handles different message types and tenant resolution.
- Files: `middleware/src/handlers/chatwoot-webhook.ts`
- Priority: High.

**Self-Healing Analysis Logic:**
- What's not tested: The fingerprinting logic and the analysis workflow invocation.
- Files: `agents/self-healing/src/index.ts`
- Priority: Medium.

---

*Concerns audit: 2025-01-24*
