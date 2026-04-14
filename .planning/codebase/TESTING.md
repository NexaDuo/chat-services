# Testing Patterns

**Analysis Date:** 2026-04-14

## Test Framework

**Runner:**
- No test runner (Vitest/Jest) is currently configured in the codebase.
- Manual validation is used via `validation/phase2_audit.sh`.

**Assertion Library:**
- None detected.

**Run Commands:**
```bash
./validation/phase2_audit.sh      # Infrastructure validation
./scripts/validate-stack.sh      # Stack health check
```

## Test File Organization

**Location:**
- Not applicable (No unit tests found).

**Naming:**
- No standard pattern established yet.

## Test Structure

**Suite Organization:**
- Currently relies on shell scripts that perform `curl` requests or check GCP resources via `gcloud` CLI.

## Mocking

**Framework:** None.

**What to Mock:**
- [Planned] Chatwoot and Dify API responses for testing the Middleware adapter.

## Fixtures and Factories

**Test Data:**
- Manual JSON payloads for webhooks are used during development.

## Coverage

**Requirements:** None currently enforced.

## Test Types

**Unit Tests:**
- [Gap] No unit tests for Middleware logic.

**Integration Tests:**
- [Gap] No automated integration tests for Chatwoot ⇄ Dify flow.

**E2E Tests:**
- [Gap] Manual testing via Chatwoot UI.

## Common Patterns

**Infrastructure Validation:**
```bash
# Pattern from validation/phase2_audit.sh
# Check if public IP is accessible on specific ports
curl -Is http://${VM_IP}:3000 | head -n 1
```

**Error Testing:**
- Currently performed manually by sending invalid payloads to the webhook and observing logs in Loki.

---

*Testing analysis: 2026-04-14*
