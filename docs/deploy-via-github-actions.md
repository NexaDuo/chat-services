# Production Deployment via GitHub Actions

Segmented workflow in `.github/workflows/deploy.yml`. Replaces local execution of
`scripts/deploy-production.sh` to prevent configuration loss between machines
(the rationale for this document is in [issue #5](https://github.com/NexaDuo/chat-services/issues/5)).

## Why Segmented?

`deploy-production.sh` performs several stages in sequence. If a late stage fails,
re-running everything (including VM recreation) is inefficient. The segmented
workflow allows re-applying only the changed layer:

| Segment | Coverage | When to Run |
|---|---|---|
| `validate` | health checks + Playwright | Always, to confirm availability |
| `routes` | `refresh-coolify-routes.sh` | When subdomains return 404/502 |
| `tenant` | direct scripted deployment | When env, compose, or tenant images change |
| `build-images` | build & push middleware/self-healing | When agent code changes |
| `bootstrap` | installs Coolify on VM | Once per VM |
| `foundation` | terraform apply foundation | Once per region; only for infra changes |
| `onboarding` | create Chatwoot+Dify admins | Once |
| `all` | full pipeline in deployment order | First-time setup or disaster recovery |

`dry_run=true` is the default. In dry-run mode:
- No `terraform apply` runs — only `plan`.
- The `build-images` job is **skipped** (image push is a side effect that generates costs).
- `routes`, `bootstrap`, `onboarding` are skipped with an informative note.

The Terraform plan appears as redacted text in the job log but **is not uploaded as an artifact** — the binary plan (`tfplan.bin`) embeds Secret Manager values and would be accessible to anyone with repository read access.

### Additional Inputs

- **`tenant_subset`** (default `all`): for `segment=tenant`, applies only specific services (e.g., `chatwoot`, `dify`, `nexaduo`, or `shared`).
- **`skip_grafana`** (default `true`): for `segment=routes`, ignores Grafana when generating the fallback Traefik config.

## Setup (Once)

### 1. Repo Vars (Settings → Secrets and variables → Actions → Variables)

| Var | Value |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/205245484827/locations/global/workloadIdentityPools/github/providers/nexaduo-chat-services` |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | `gh-deployer@nexaduo-492818.iam.gserviceaccount.com` |
| `TF_BACKEND_PREFIX_FOUNDATION` | `terraform/state/foundation` |
| `TF_BACKEND_PREFIX_TENANT` | `terraform/state/production/tenant` |

### 2. Repo Secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret | Value |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Same token as in local `terraform.tfvars`. Required for Cloudflare provider. |

Other secrets (Postgres, Chatwoot, Dify, OAuth) are already in GCP Secret Manager and read by Terraform via `data`.

### 3. `gh-deployer` SA on GCP (Create Once)

The existing `gh-publisher` SA only has Artifact Registry permissions. For the deployment workflow, we need a dedicated SA with broader scope.

```bash
PROJECT=nexaduo-492818
SA=gh-deployer
gcloud iam service-accounts create $SA \
  --display-name="GitHub Actions deployer" \
  --project=$PROJECT

# Roles for terraform apply (foundation + tenant)
for role in \
  roles/compute.admin \
  roles/iam.serviceAccountUser \
  roles/secretmanager.secretAccessor \
  roles/storage.admin \
  roles/dns.admin \
  roles/iap.tunnelResourceAccessor \
  roles/artifactregistry.admin \
; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:${SA}@${PROJECT}.iam.gserviceaccount.com" \
    --role="$role"
done

# Bind WIF: allow the repository to impersonate this SA
gcloud iam service-accounts add-iam-policy-binding \
  ${SA}@${PROJECT}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/205245484827/locations/global/workloadIdentityPools/github/attribute.repository/NexaDuo/chat-services" \
  --project=$PROJECT
```

### 4. Snapshot of `terraform.tfvars` to Secret Manager

The workflow does not have the tfvars file in the repo (it is in .gitignore). It reads from Secret Manager:

```bash
gcloud secrets create terraform_tfvars_production \
  --replication-policy=automatic \
  --project=$PROJECT
gcloud secrets versions add terraform_tfvars_production \
  --data-file=infrastructure/terraform/envs/production/terraform.tfvars \
  --project=$PROJECT
```

## How to Run

GitHub UI: **Actions** → **Deploy production (segmented)** → **Run workflow** → choose `segment` and `dry_run`.

CLI:
```bash
# Dry-run of tenant
gh workflow run deploy.yml -f segment=tenant -f dry_run=true

# Apply only routes (fix 502), skipping Grafana
gh workflow run deploy.yml -f segment=routes -f dry_run=false -f skip_grafana=true

# Full pipeline
gh workflow run deploy.yml -f segment=all -f dry_run=false
```

## Troubleshooting

### "Permission denied" in terraform apply
Missing role on `gh-deployer` SA. Check with:
```bash
gcloud projects get-iam-policy nexaduo-492818 --format=json \
  | jq '.bindings[] | select(.members[] | contains("gh-deployer"))'
```

### "Could not load backend state from gs://..."
Wrong `TF_BACKEND_PREFIX_*`. The real state is in `terraform/state/foundation`. Check list:
```bash
gcloud storage ls -r gs://nexaduo-terraform-state/terraform/
```
