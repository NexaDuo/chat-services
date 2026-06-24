# Fix Middleware Provisioning 401 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set the `CHATWOOT_PLATFORM_TOKEN` environment variable in the middleware service using GCP Secret Manager to resolve the 401 Unauthorized error during tenant provisioning.

**Architecture:** Fetch the new `chatwoot_platform_token` secret in the tenant Terraform layer and add it as a Coolify service environment variable (`CHATWOOT_PLATFORM_TOKEN`) for the middleware service.

**Tech Stack:** Terraform, Google Cloud Secret Manager, Coolify API/Provider.

## Global Constraints
- Avoid manual VM changes for persistent configs; use versioned Terraform configs.
- Monitor execution of the deploy pipelines on GitHub Actions to ensure success.

---

### Task 1: Fetch and configure Secret in Terraform

**Files:**
- Modify: `infrastructure/terraform/envs/production/tenant/secrets.tf`
- Modify: `infrastructure/terraform/envs/production/tenant/main.tf`

**Interfaces:**
- Consumes: Google Secret Manager secret `chatwoot_platform_token`.
- Produces: Environment variable `CHATWOOT_PLATFORM_TOKEN` in Coolify service environment configurations for `nexaduo` (middleware).

- [ ] **Step 1: Reference secret in secrets.tf**

Add the data block to import the secret from Google Cloud Secret Manager.

```terraform
# infrastructure/terraform/envs/production/tenant/secrets.tf
# Lines 84-86 (append at the end of the file):

data "google_secret_manager_secret_version" "chatwoot_platform_token" {
  secret = "chatwoot_platform_token"
}
```

- [ ] **Step 2: Add environment variable in main.tf**

Pass the secret data as `CHATWOOT_PLATFORM_TOKEN` env var to the `nexaduo` middleware service.

```terraform
# infrastructure/terraform/envs/production/tenant/main.tf
# Lines 353-355 (add under the nexaduo service env blocks):

  env {
    key        = "CHATWOOT_PLATFORM_TOKEN"
    value      = data.google_secret_manager_secret_version.chatwoot_platform_token.secret_data
    is_literal = true
  }
```

- [ ] **Step 3: Run terraform fmt to verify style**

Run: `terraform fmt -check -diff` inside the folder `infrastructure/terraform/envs/production/tenant`
Expected: Return with exit code 0 (no style errors).

- [ ] **Step 4: Commit the configuration changes**

```bash
git add infrastructure/terraform/envs/production/tenant/secrets.tf infrastructure/terraform/envs/production/tenant/main.tf
git commit -m "feat(infra): add CHATWOOT_PLATFORM_TOKEN env var to middleware service"
```

---

### Task 2: Deploy and Verify E2E Tenant Provisioning

**Files:**
- Monitor: GitHub Actions deployment run logs
- Test: Playwright smoke validation suite

- [ ] **Step 1: Push changes to trigger CI/CD pipeline**

Run: `git push origin main`
Expected: Success.

- [ ] **Step 2: Watch deploy progress**

Run: `gh run list --limit 2` and watch for the status of `Deploy production (segmented)` run.
Expected: Runs to completion, executing the `tenant`, `routes`, `sync`, and `validate` segments successfully.

- [ ] **Step 3: Verify E2E Provisioning**

Wait for the deployment to finish and verify that the provisioning endpoint `/admin/api/tenants/nexaduo/provision` works (as verified by `15-admin-portal.spec.ts` in the `validate` stage of the pipeline).
