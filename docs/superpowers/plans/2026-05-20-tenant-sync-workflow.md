# Secure Tenant Sync Workflow (GCloud-Only Secrets) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automate tenant configuration synchronization and validation via GitHub Actions, strictly using GCP Secret Manager for all production credentials and Workload Identity Federation (WIF) for authentication.

**Architecture:** 
1. **Validation Workflow (`validate-tenants.yml`):** Runs on Push/PR. Checks YAML syntax and script type-safety.
2. **Production Sync Segment:** Adds a `sync` option to `deploy.yml`. 
3. **Secret Retrieval:** The workflow fetches `production_database_url` and `handoff_shared_secret` from GCP Secret Manager using `gcloud` and sets them as masked GitHub Action environment variables.
4. **Security:** Zero static keys in GitHub. All access is identity-based (WIF).

**Tech Stack:** GitHub Actions, Node.js, GCP Secret Manager, gcloud CLI, WIF.

---

### Task 1: Add `sync` Segment to `deploy.yml` with GCP Secret Retrieval

**Files:**
- Modify: `.github/workflows/deploy.yml`

- [ ] **Step 1: Add `sync` to inputs**
Add `sync` to the `segment` choice options.

- [ ] **Step 2: Add the `sync` job with dynamic secret fetching**

```yaml
  sync:
    if: inputs.segment == 'sync' || inputs.segment == 'all'
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4

      - id: auth
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ vars.GCP_WORKLOAD_IDENTITY_PROVIDER }}
          service_account: ${{ vars.GCP_DEPLOYER_SERVICE_ACCOUNT }}

      - uses: google-github-actions/setup-gcloud@v2

      - name: Fetch Secrets from GCP
        id: gcp-secrets
        run: |
          # Fetch secrets and mask them immediately for GitHub logs
          DB_URL=$(gcloud secrets versions access latest --secret="production_database_url" --project="${{ env.PROJECT_ID }}")
          echo "::add-mask::$DB_URL"
          echo "database_url=$DB_URL" >> "$GITHUB_OUTPUT"
          
          HANDOFF=$(gcloud secrets versions access latest --secret="handoff_shared_secret" --project="${{ env.PROJECT_ID }}")
          echo "::add-mask::$HANDOFF"
          echo "handoff_secret=$HANDOFF" >> "$GITHUB_OUTPUT"

      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run tenant sync
        env:
          DATABASE_URL: ${{ steps.gcp-secrets.outputs.database_url }}
          HANDOFF_SHARED_SECRET: ${{ steps.gcp-secrets.outputs.handoff_secret }}
        run: npm run tenants:sync
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(ci): add tenant sync segment fetching secrets from GCP"
```

### Task 2: Create Automatic Validation Workflow

**Files:**
- Create: `.github/workflows/validate-tenants.yml`

- [ ] **Step 1: Define the validation workflow (no secrets needed for plan/lint)**

```yaml
name: Validate Tenant Configuration

on:
  push:
    branches: [ main ]
    paths:
      - 'tenants.yaml'
      - 'scripts/sync-tenants.ts'
  pull_request:
    branches: [ main ]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
      
      - name: Install dependencies
        run: npm ci
      
      - name: Lint and Typecheck
        run: npm run typecheck
      
      - name: Validate YAML Schema
        run: npx tsx -e "import fs from 'fs'; import yaml from 'yaml'; yaml.parse(fs.readFileSync('tenants.yaml', 'utf8'))"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/validate-tenants.yml
git commit -m "feat(ci): add automatic validation for tenant configuration"
```

### Task 3: Ensure Secret Masking in `sync-tenants.ts`

**Files:**
- Modify: `scripts/sync-tenants.ts`

- [ ] **Step 1: Audit script for logging**
Ensure `console.log` never outputs `process.env.DATABASE_URL` or secret values.

- [ ] **Step 2: Commit**

```bash
git commit -m "chore(tenants): audit sync script for secret logging"
```

### Task 4: Prepare Secret Manager (Manual/Check)

**Files:**
- N/A (Manual)

- [ ] **Step 1: Verify/Create secrets in GCP**
Ensure `production_database_url` and `handoff_shared_secret` exist in the GCP project `nexaduo-492818`.

```bash
# Example check
gcloud secrets list --project=nexaduo-492818
```

- [ ] **Step 2: Update documentation**
Update `docs/deploy-via-github-actions.md` to list these new required secrets in Secret Manager.

- [ ] **Step 3: Commit documentation**
```bash
git commit -m "docs(ci): update deployment docs with Secret Manager requirements"
```
