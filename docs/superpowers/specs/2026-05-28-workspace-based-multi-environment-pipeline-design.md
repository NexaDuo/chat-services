# Workspace-Based Multi-Environment Pipeline Design Specification

## Overview

This specification details the dynamic, environment-aware CI/CD workflow driven by the `tenants.yaml` configuration. The pipeline will automatically deploy and validate staging tenants on Pull Requests (opened on any branch) and production tenants on pushes to the `main` branch. 

Using Terraform Workspaces (Approach B), we avoid manual configuration and folder duplication, utilizing a single dynamic config root that evaluates the current workspace context (`staging` vs `production`).

---

## 1. Architecture & Flow Diagram

The dynamic workflow execution flow maps branch changes to GHA matrix runs and Terraform workspaces:

```
[Branch Event]
   │
   ├──▶ Pull Request ──▶ TARGET_ENVIRONMENT: staging ────▶ Select TF Workspace: staging
   │                                                               │
   │                                                               ▼
   │                                                      Execute GHA Matrix (Staging Tenants)
   │
   └──▶ Push to main ──▶ TARGET_ENVIRONMENT: production ──▶ Select TF Workspace: production
                                                                   │
                                                                   ▼
                                                          Execute GHA Matrix (Prod Tenants)
```

---

## 2. Triggering and Inputs Resolution

We will modify [.github/workflows/deploy.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/.github/workflows/deploy.yml) to register automatic branch triggers. To resolve parameters when running automated events without inputs context, we dynamically map the parameters globally.

### Global Workflow Environment Block
```yaml
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

---

## 3. Concurrency & Environment Isolation

### Smart Concurrency
To allow staging PRs to run concurrently without blocking production hotfixes, and to auto-cancel redundant workflow runs when developers commit rapidly to a PR:
```yaml
concurrency:
  group: deploy-${{ github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production') }}-${{ github.ref }}
  cancel-in-progress: ${{ (github.event.inputs.environment || (github.event_name == 'pull_request' && 'staging' || 'production')) == 'staging' }}
```

### Dynamic Secret Management
Each job dynamically binds to the corresponding GitHub Environment, locking down vars and secrets dynamically:
```yaml
    environment:
      name: ${{ env.TARGET_ENVIRONMENT }}
      url: ${{ needs.resolve-env.outputs.primary_url }}
```

Retrieving configurations from GCP Secret Manager resolves dynamically by suffixing the environment name:
```bash
gcloud secrets versions access latest \
  --secret=terraform_tfvars_${{ env.TARGET_ENVIRONMENT }} \
  --project="${PROJECT_ID}" > "${TFVARS_PATH}"
```

---

## 4. Initialization Job & GHA Matrix Generation

To avoid hardcoded URLs, we introduce a fast `resolve-env` initialization job at the start of the workflow. This job parses `tenants.yaml` and outputs the URLs and matrix parameters.

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

Subsequent jobs will leverage `needs: [resolve-env]` and iterate dynamically using:
```yaml
    strategy:
      matrix:
        tenant: ${{ fromJson(needs.resolve-env.outputs.tenants) }}
```

---

## 5. Terraform Workspaces Refactoring (Approach B)

We reuse the single Terraform configuration root inside `infrastructure/terraform/envs/production` for both environments, driven by `terraform.workspace`.

Inside each Terraform job, we select or initialize the workspace:
```bash
terraform workspace select "${{ env.TARGET_ENVIRONMENT }}" || terraform workspace new "${{ env.TARGET_ENVIRONMENT }}"
```

### Dynamic HCL Refactoring
*   **Foundation main.tf**: Compute VM names, Cloudflare tunnel names, DNS records, and bucket names will dynamically evaluate the workspace name (e.g. `nexaduo-chat-services-staging` for staging, and `nexaduo-chat-services` for production). Non-production environments will scale down the compute capacity (`e2-medium` machine type and `30GB` storage disk) to minimize costs.
*   **Tenant main.tf**: Coolify project and service definitions will deploy dynamically to the Coolify environment name that matches `terraform.workspace`, dynamically resolving and interpolating all domain names and Google Client OAuth callback URLs.

---

## 6. Verification and Testing

1.  **Playwright OAuth Suite**: Update `onboarding/tests/04-oauth.spec.ts` to parse `tenants.yaml` and verify login redirects against each active tenant corresponding to the running environment.
2.  **Public Smoke Reachability**: Loop dynamically over the GHA matrix tenants to probe HTTPS responsiveness (2xx/3xx/401/403) of all public interfaces.
