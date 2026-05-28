# Workspace-Based Multi-Environment Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish an automated, branch-driven multi-environment deploy pipeline using Terraform workspaces (Approach B) and GHA dynamic matrices, deploying staging tenants on PR commits and production tenants on pushes to main.

**Architecture:** 
1. **Automated Branch Triggers**: Update GHA `deploy.yml` to trigger on PRs (staging environment target) and pushes to `main` (production environment target), using env resolvers to unify inputs and automated triggers.
2. **Dynamic Matrix Extraction**: Implement a fast GHA initialization job `resolve-env` that parses `tenants.yaml` to dynamically build a JSON list of active tenants for GHA matrix testing and smoke checks.
3. **Terraform Workspace Integration**: Refactor HCL files under `envs/production` to dynamically compute instances, DNS, buckets, and Coolify names based on the selected workspace.

**Tech Stack:** Terraform, GitHub Actions, Playwright, TypeScript, Node.js, yq/jq

---

## File Structure Changes

### Modified Files:
- [04-oauth.spec.ts](file:///home/ubuntu-24/repos/NexaDuo/chat-services/onboarding/tests/04-oauth.spec.ts) — Refactor Playwright tests to dynamically load tenants from `tenants.yaml` matching the environment.
- [deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml) — Introduce automated triggers, dynamic global envs, concurrency locks, `resolve-env` job, and matrix-based validation/onboarding.
- [main.tf (foundation)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/foundation/main.tf) — Refactor variables and resource names to evaluate workspace.
- [main.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/main.tf) — Refactor names, urls, and environments to evaluate workspace.
- [variables.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/variables.tf) — Declare the `base_domain` variable.

---

## Proposed Tasks

### Task 1: Parameterize Playwright Google OAuth Tests

**Files:**
- Modify: [onboarding/tests/04-oauth.spec.ts](file:///home/ubuntu-24/repos/NexaDuo/chat-services/onboarding/tests/04-oauth.spec.ts)
- Test: Run Playwright suite locally

- [ ] **Step 1: Refactor 04-oauth.spec.ts to execute parameterized tests**

Replace [onboarding/tests/04-oauth.spec.ts](file:///home/ubuntu-24/repos/NexaDuo/chat-services/onboarding/tests/04-oauth.spec.ts) with dynamic tenant list parsing:

```typescript
import { test, expect } from '@playwright/test';
import fs from 'fs';
import path from 'path';
import yaml from 'yaml';

interface TenantConfig {
  slug: string;
  name: string;
  chatwoot_account_id: number;
  status: string;
  environment: string;
  infra?: {
    type: string;
    chatwoot_url?: string;
    dify_url?: string;
  };
}

interface TenantsYaml {
  global: {
    gcp_project_id: string;
    base_domain: string;
  };
  tenants: TenantConfig[];
}

const targetEnv = process.env.ENVIRONMENT || 'production';
const yamlPath = path.resolve(process.cwd(), '../tenants.yaml');
const fileContent = fs.readFileSync(yamlPath, 'utf8');
const config = yaml.parse(fileContent) as TenantsYaml;

const activeTenants = config.tenants.filter(t => t.environment === targetEnv && t.infra?.chatwoot_url && t.infra?.dify_url);

test.describe(`Google OAuth init endpoints - Environment: ${targetEnv}`, () => {
  for (const tenant of activeTenants) {
    const chatwootUrl = tenant.infra!.chatwoot_url!;
    const difyUrl = tenant.infra!.dify_url!;

    test(`${tenant.name}: Chatwoot redirects to accounts.google.com`, async ({ browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      
      console.log(`Checking ${tenant.slug} Chatwoot OAuth at ${chatwootUrl}/auth/google_oauth2...`);
      await page.goto(chatwootUrl);
      
      const responsePromise = page.waitForNavigation();
      await page.evaluate((url) => {
        const form = document.createElement('form');
        form.method = 'POST';
        form.action = url;
        document.body.appendChild(form);
        form.submit();
      }, `${chatwootUrl}/auth/google_oauth2`);
      
      const response = await responsePromise;
      const finalUrl = page.url();
      const body = await response?.text() || '';
      
      expect(
        finalUrl, 
        `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
      ).toMatch(/^https:\/\/accounts\.google\.com\//);
      expect(response?.status()).toBe(200);

      await ctx.close();
    });

    test(`${tenant.name}: Dify redirects to accounts.google.com`, async ({ browser }) => {
      const ctx = await browser.newContext();
      const page = await ctx.newPage();
      
      console.log(`Checking ${tenant.slug} Dify OAuth at ${difyUrl}/console/api/oauth/login/google...`);
      const response = await page.goto(`${difyUrl}/console/api/oauth/login/google`);
      
      const finalUrl = page.url();
      const res = await response;
      const status = res?.status();
      const body = await res?.text() || '';

      expect(status).toBe(200);
      expect(
        finalUrl,
        `Expected redirect chain to end at accounts.google.com but got ${finalUrl}. Body: ${body}`
      ).toMatch(/^https:\/\/accounts\.google\.com\//);

      await ctx.close();
    });
  }
});
```

- [ ] **Step 2: Run verification test locally to ensure correctness**

Run: `npx playwright test onboarding/tests/04-oauth.spec.ts`
Expected: Test passes successfully against active production tenants.

- [ ] **Step 3: Commit**

```bash
git add onboarding/tests/04-oauth.spec.ts
git commit -m "test(onboarding): parameterize oauth checks to dynamically load tenants from tenants.yaml"
```

---

### Task 2: Refactor deploy.yml with Auto Triggers & Matrix Validation

**Files:**
- Modify: [.github/workflows/deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml)
- Test: Dry-run workflow in GHA

- [ ] **Step 1: Update on, env, and concurrency in deploy.yml**

Update [.github/workflows/deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml) triggers, concurrency, and dynamic global variable definitions:

```yaml
on:
  workflow_dispatch:
    inputs:
      segment:
        description: 'Which layer to apply'
        required: true
        type: choice
        default: validate
        options:
          - validate
          - routes
          - sync
          - tenant
          - build-images
          - bootstrap
          - foundation
          - onboarding
          - all
      dry_run:
        description: 'Plan-only'
        required: true
        type: boolean
        default: true
      environment:
        description: 'Target Environment'
        required: true
        type: choice
        default: staging
        options:
          - staging
          - production
  pull_request:
    branches: [ main ]
  push:
    branches: [ main ]

# Prevent two runs of the same environment racing on terraform state.
# Staging workflows cancel older active runs on the same branch.
concurrency:
  group: deploy-${{ github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production') }}-${{ github.ref }}
  cancel-in-progress: ${{ (github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production')) == 'staging' }}

env:
  TZ: America/Sao_Paulo
  TF_VERSION: 1.9.8
  PROJECT_ID: nexaduo-492818
  ZONE: us-central1-b
  REGION: us-central1
  VM_NAME: ${{ (github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production')) == 'production' && 'nexaduo-chat-services' || 'nexaduo-chat-services-staging' }}
  BASE_DOMAIN: nexaduo.com
  TFVARS_PATH: infrastructure/terraform/envs/production/terraform.tfvars
  
  # Dynamic Fallbacks for automated triggers
  TARGET_ENVIRONMENT: ${{ github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production') }}
  IS_DRY_RUN: ${{ github.event.inputs.dry_run || 'false' }}
  TARGET_SEGMENT: ${{ github.event.inputs.segment || 'all' }}
```

- [ ] **Step 2: Add resolve-env job at pipeline root**

Insert `resolve-env` as the very first job inside `jobs:` of [.github/workflows/deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml):

```yaml
jobs:
  resolve-env:
    runs-on: ubuntu-latest
    outputs:
      primary_url: ${{ steps.extract.outputs.primary_url }}
      tenants: ${{ steps.extract.outputs.tenants }}
    steps:
      - uses: actions/checkout@v4

      - name: Extract Tenant Metadata
        id: extract
        run: |
          # Extract all tenants matching the environment to a compact JSON array
          TENANTS_JSON=$(yq eval -o=json '.tenants[] | select(.environment == "${{ env.TARGET_ENVIRONMENT }}")' tenants.yaml | jq -c -s '.')
          echo "tenants=$TENANTS_JSON" >> "$GITHUB_OUTPUT"
          
          # Grab primary tenant url for GHA Environment link
          PRIMARY_URL=$(echo "$TENANTS_JSON" | jq -r '.[0].infra.chatwoot_url // empty')
          [[ -n "$PRIMARY_URL" ]] || PRIMARY_URL="https://chat${{ env.TARGET_ENVIRONMENT == 'production' && '' || '-stg' }}.nexaduo.com"
          echo "primary_url=$PRIMARY_URL" >> "$GITHUB_OUTPUT"
          
          # Print for verification
          echo "Active Tenants: $TENANTS_JSON"
          echo "Primary Endpoint: $PRIMARY_URL"
```

- [ ] **Step 3: Update downstream jobs in deploy.yml**

Update all dynamic jobs (`foundation`, `bootstrap`, `build-images`, `tenant`, `routes`, `sync`, `onboarding`, `validate`) to evaluate `env.TARGET_SEGMENT`, `env.IS_DRY_RUN`, `env.TARGET_ENVIRONMENT`, and declare `needs: [resolve-env]`:

*   **Job conditions**: Replace `inputs.segment == '...'` with `env.TARGET_SEGMENT == '...'`.
*   **Restore secrets step**: Suffix the secret fetch dynamically:
    ```bash
    --secret=terraform_tfvars_${{ env.TARGET_ENVIRONMENT }}
    ```
*   **Workspace select step**: Under both `foundation` and `tenant` jobs immediately following `Terraform init`:
    ```yaml
          - name: Select or Create Workspace
            working-directory: infrastructure/terraform/envs/production/foundation # or tenant
            run: |
              terraform workspace select "${{ env.TARGET_ENVIRONMENT }}" || terraform workspace new "${{ env.TARGET_ENVIRONMENT }}"
    ```
*   **Apply step condition**: Replace `inputs.dry_run == false` with `env.IS_DRY_RUN == 'false'`.
*   **Sync step execution**: Update tenant sync parameters:
    ```bash
    npm run tenants:sync -- "${{ env.TARGET_ENVIRONMENT }}"
    ```

- [ ] **Step 4: Refactor validate job into a dynamic GHA Matrix**

Replace the `validate` job in [.github/workflows/deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml) with a dynamic environment-filtering matrix check:

```yaml
  validate:
    needs: [resolve-env, onboarding]
    if: |
      always() &&
      (env.TARGET_SEGMENT == 'validate' ||
       (env.TARGET_SEGMENT == 'all' && (needs.onboarding.result == 'success' || needs.onboarding.result == 'skipped')))
    runs-on: ubuntu-latest
    timeout-minutes: 15
    strategy:
      matrix:
        tenant: ${{ fromJson(needs.resolve-env.outputs.tenants) }}
    steps:
      - uses: actions/checkout@v4

      - name: Public smoke (HTTPS reachability)
        run: |
          set -u
          fail=0
          
          chatwoot_url="${{ matrix.tenant.infra.chatwoot_url }}"
          dify_url="${{ matrix.tenant.infra.dify_url }}"
          
          # Check Chatwoot
          echo "Checking Chatwoot at ${chatwoot_url} ..."
          code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 -L "${chatwoot_url}/" || echo "ERR")
          echo "  -> Status: ${code}"
          case "${code}" in
            2*|3*|401|403) ;;
            *) echo "::error::Chatwoot ${chatwoot_url} returned ${code}"; fail=1 ;;
          esac

          # Check Dify console API setup check
          echo "Checking Dify setup API at ${dify_url}/console/api/setup ..."
          code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "${dify_url}/console/api/setup" || echo "ERR")
          echo "  -> Status: ${code}"
          case "${code}" in
            200|403) ;;
            *) echo "::error::Dify API setup check failed for ${dify_url} with status ${code}"; fail=1 ;;
          esac

          [[ $fail -eq 0 ]] || { echo "::error::Smoke checks failed."; exit 1; }

      - uses: actions/setup-node@v4
        with:
          node-version: '22'
          cache: 'npm'
          cache-dependency-path: onboarding/package-lock.json

      - name: Install Playwright
        working-directory: onboarding
        run: |
          npm ci
          npx playwright install --with-deps chromium

      - name: Run Playwright OAuth checks
        working-directory: onboarding
        env:
          ENVIRONMENT: ${{ env.TARGET_ENVIRONMENT }}
        run: npx playwright test 04-oauth.spec.ts

      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report-${{ matrix.tenant.slug }}-${{ github.run_id }}
          path: onboarding/playwright-report
          retention-days: 14
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat(workflow): implement branch-driven deployment triggers and dynamic tenant matrix checks"
```

---

### Task 3: Refactor Terraform for Workspaces (Approach B)

**Files:**
- Modify: [main.tf (foundation)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/foundation/main.tf)
- Modify: [main.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/main.tf)
- Modify: [variables.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/variables.tf)

- [ ] **Step 1: Refactor foundation main.tf to support workspaces**

Replace [main.tf (foundation)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/foundation/main.tf) with dynamic workspace interpolations:

```hcl
locals {
  env       = terraform.workspace
  is_prod   = local.env == "production"
  vm_suffix = local.is_prod ? "" : "-${local.env}"
  vm_name   = "${var.app_name}${local.vm_suffix}"

  # Scaled down sizes for non-production environments to minimize costs
  machine_type = local.is_prod ? var.machine_type : "e2-medium"
  disk_size    = local.is_prod ? var.disk_size : 30

  # Environment suffix for subdomains
  dns_suffix = local.is_prod ? "" : "-stg"
}

module "vm" {
  source = "../../../modules/gcp-vm"

  project_id            = var.gcp_project_id
  region                = var.gcp_region
  zone                  = var.gcp_zone
  name                  = local.vm_name
  machine_type          = local.machine_type
  disk_size             = local.disk_size
  ssh_user              = var.ssh_user
  ssh_key               = var.ssh_key
  service_account_email = "${var.gcp_project_number}-compute@developer.gserviceaccount.com"
}

module "dns_chat" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "chat${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_dify" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "dify${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_grafana" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "grafana${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_evolution" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "evolution${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_middleware" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "middleware${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_coolify" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "coolify${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "backup_storage" {
  source = "../../../modules/gcp-storage"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  bucket_name = local.is_prod ? var.backup_bucket_name : "${var.backup_bucket_name}-${local.env}"
}

module "tunnel" {
  source = "../../../modules/cloudflare-tunnel"

  account_id  = var.cloudflare_account_id
  name        = "${var.app_name}-${local.env}-tunnel"
  zone_id     = var.cloudflare_zone_id
  base_domain = var.base_domain
  proxied     = true
}

resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}

module "artifact_registry" {
  source = "../../../modules/gcp-artifact-registry"

  project_id    = var.gcp_project_id
  location      = var.gcp_region
  repository_id = local.is_prod ? var.artifact_registry_repository_id : "${var.artifact_registry_repository_id}-${local.env}"

  depends_on = [google_project_service.required]
}

module "gh_publisher" {
  source = "../../../modules/gcp-gh-publisher"

  project_id                      = var.gcp_project_id
  github_repository               = var.github_repository
  artifact_registry_location      = module.artifact_registry.location
  artifact_registry_repository_id = module.artifact_registry.repository_id
}

resource "google_artifact_registry_repository_iam_member" "vm_reader" {
  project    = var.gcp_project_id
  location   = module.artifact_registry.location
  repository = module.artifact_registry.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.gcp_project_number}-compute@developer.gserviceaccount.com"
}

output "tunnel_token" {
  value     = module.tunnel.tunnel_token
  sensitive = true
}

output "tunnel_id" {
  value = module.tunnel.tunnel_id
}

output "artifact_registry_url" {
  description = "Image prefix for the tenant layer: <url>/<image>:<tag>"
  value       = module.artifact_registry.repository_url
}

output "gh_publisher_service_account" {
  value = module.gh_publisher.service_account_email
}

output "gh_workload_identity_provider" {
  description = "Pass this as workload_identity_provider in .github/workflows/publish-images.yml"
  value       = module.gh_publisher.workload_identity_provider
}
```

- [ ] **Step 2: Declare base_domain in tenant variables.tf**

Add `base_domain` input in [variables.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/variables.tf):

```hcl
variable "base_domain" {
  type    = string
  default = "nexaduo.com"
}
```

- [ ] **Step 3: Refactor tenant main.tf to support workspaces**

Modify [main.tf (tenant)](file:///home/ubuntu-24/repos/NexaDuo/chat-services/infrastructure/terraform/envs/production/tenant/main.tf). Replace the lookups and `coolify_project.main` block with workspace-driven locals:

```hcl
# Look up the local Coolify server (single-server setup; index [0]).
data "coolify_servers" "main" {}

locals {
  env            = terraform.workspace
  is_prod        = local.env == "production"
  service_suffix = local.is_prod ? "" : "-${local.env}"
  dns_suffix     = local.is_prod ? "" : "-stg"

  chatwoot_frontend_url = "https://chat${local.dns_suffix}.${var.base_domain}"
  dify_url              = "https://dify${local.dns_suffix}.${var.base_domain}"
}

resource "coolify_project" "main" {
  name = "NexaDuo Chat Services (${local.env})"
}
```

Update each of the `coolify_service` names and environments:

```hcl
resource "coolify_service" "shared" {
  name             = "nexaduo-shared${local.service_suffix}"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = local.env
  instant_deploy   = true
  # ... existing compose and lifecycle blocks
}

resource "coolify_service" "chatwoot" {
  name             = "nexaduo-chatwoot${local.service_suffix}"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = local.env
  instant_deploy   = true
  # ... existing depends_on and lifecycle blocks
}

# Update envs in coolify_service_envs.chatwoot:
  env {
    key   = "CHATWOOT_FRONTEND_URL"
    value = local.chatwoot_frontend_url
  }
  env {
    key   = "GOOGLE_OAUTH_CALLBACK_URL"
    value = "${local.chatwoot_frontend_url}/omniauth/google_oauth2/callback"
  }

resource "coolify_service" "dify" {
  name             = "nexaduo-dify${local.service_suffix}"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = local.env
  instant_deploy   = true
  # ... existing depends_on and lifecycle blocks
}

# Update envs in coolify_service_envs.dify:
  env {
    key   = "DIFY_CONSOLE_API_URL"
    value = local.dify_url
  }
  env {
    key   = "DIFY_APP_API_URL"
    value = local.dify_url
  }
  env {
    key   = "NEXT_PUBLIC_COOKIE_DOMAIN"
    value = "dify${local.dns_suffix}.${var.base_domain}"
  }
  env {
    key   = "COOKIE_DOMAIN"
    value = "dify${local.dns_suffix}.${var.base_domain}"
  }
  env {
    key   = "CONSOLE_WEB_URL"
    value = local.dify_url
  }
  env {
    key   = "SERVICE_API_URL"
    value = local.dify_url
  }
  env {
    key   = "APP_WEB_URL"
    value = local.dify_url
  }

resource "coolify_service" "nexaduo" {
  name             = "nexaduo-app${local.service_suffix}"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = local.env
  instant_deploy   = true
  # ... existing depends_on and lifecycle blocks
}

# Update env in coolify_service_envs.nexaduo:
  env {
    key   = "GF_SERVER_ROOT_URL"
    value = "https://grafana${local.dns_suffix}.${var.base_domain}"
  }
```

- [ ] **Step 4: Commit**

```bash
git add infrastructure/terraform/envs/production/foundation/main.tf infrastructure/terraform/envs/production/tenant/main.tf infrastructure/terraform/envs/production/tenant/variables.tf
git commit -m "refactor(terraform): support workspace-driven multi-environment deployments (Approach B)"
```
