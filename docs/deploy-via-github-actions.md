# Deploy de produção via GitHub Actions

Workflow segmentado em `.github/workflows/deploy.yml`. Substitui execução local de
`scripts/deploy-production.sh` para evitar perda de configuração entre máquinas
(o motivo deste documento existir está em [issue #5](https://github.com/NexaDuo/chat-services/issues/5)).

## Por que segmentado?

`deploy-production.sh` faz 7 etapas em sequência. Se a etapa 5 falha, você
re-roda tudo (incluindo recriar VM). O workflow segmentado permite re-aplicar
só a camada que mudou:

| Segment | Cobertura | Quando rodar |
|---|---|---|
| `validate` | health checks + Playwright | Sempre, pra confirmar que está de pé |
| `routes` | `refresh-coolify-routes.sh` | Quando subdomínios retornam 404/502 |
| `tenant` | terraform apply tenant (Coolify services + envs) | Quando muda env, compose, ou imagem de tenant |
| `build-images` | build & push middleware/self-healing | Quando muda código dos agentes |
| `bootstrap` | instala Coolify na VM | Uma vez por VM |
| `foundation` | terraform apply foundation (VM, VPC, DNS, Tunnel, AR) | Uma vez por região; re-rodar só pra mudar infra |
| `onboarding` | criar admins Chatwoot+Dify | Uma vez |
| `all` | pipeline completo na ordem do `deploy-production.sh` | First-time setup ou disaster recovery |

`dry_run=true` é o default. Em modo dry-run:
- Nenhum `terraform apply` roda — só `plan`.
- O job `build-images` é **pulado** (push de imagem é efeito colateral, gera tag órfã + custo de Artifact Registry).
- `routes`, `bootstrap`, `onboarding` ficam em "skip" com nota informativa.

O plano do terraform aparece como texto redacted no log do job, mas **não é uploadado como artifact** — o plano binário (`tfplan.bin`) embute valores de secrets do Secret Manager (Postgres password, OAuth secret, Cloudflare token) e ficaria acessível a qualquer pessoa com Actions read.

### Inputs adicionais

- **`tenant_subset`** (default `all`): para `segment=tenant`, aplica via `-target` só `chatwoot`, `dify`, `nexaduo` ou `shared`. Funciona depois do primeiro tenant apply popular o state.
- **`skip_grafana`** (default `true`): para `segment=routes`, ignora Grafana ao gerar o fallback Traefik. Útil enquanto `nexaduo-app` está exited (issue #5).

## Setup (uma vez)

### 1. Repo vars (Settings → Secrets and variables → Actions → Variables)

| Var | Valor |
|---|---|
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | `projects/205245484827/locations/global/workloadIdentityPools/github/providers/nexaduo-chat-services` |
| `GCP_DEPLOYER_SERVICE_ACCOUNT` | `gh-deployer@nexaduo-492818.iam.gserviceaccount.com` *(ver passo 3)* |
| `TF_BACKEND_PREFIX_FOUNDATION` | `terraform/state/foundation` |
| `TF_BACKEND_PREFIX_TENANT` | `terraform/state/production/tenant` |

⚠️ **Por que `terraform/state/...` em vez de `terraform/foundation/`**: o state real está
em `terraform/state/foundation/` (atualizado 2026-04-25, 50 KB, com a VM, DNS,
Tunnel). Os paths que `deploy-production.sh` usa (`terraform/foundation/`,
`terraform/tenant/`) ficaram com states fantasma de uma migração que não foi
até o fim. Ver issue #5 para o histórico.

### 2. Repo secrets (Settings → Secrets and variables → Actions → Secrets)

| Secret | Valor |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Mesmo token que está em `terraform.tfvars` local. Necessário para o provider Cloudflare ler/aplicar DNS, Tunnel. |

Os outros segredos (Postgres, Chatwoot, Dify, OAuth) já estão no GCP Secret Manager
e são lidos pelo terraform via `data "google_secret_manager_secret_version"`.

### 3. SA `gh-deployer` no GCP (criar uma vez)

O SA `gh-publisher` existente só tem permissão de Artifact Registry. Para o workflow
de deploy precisamos de um SA dedicado com mais escopo.

```bash
PROJECT=nexaduo-492818
SA=gh-deployer
gcloud iam service-accounts create $SA \
  --display-name="GitHub Actions deployer" \
  --project=$PROJECT

# Roles para terraform apply (foundation + tenant)
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

# Bind WIF: permitir que o repo NexaDuo/chat-services impersone esse SA
gcloud iam service-accounts add-iam-policy-binding \
  ${SA}@${PROJECT}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/205245484827/locations/global/workloadIdentityPools/github/attribute.repository/NexaDuo/chat-services" \
  --project=$PROJECT
```

### 4. Snapshot do `terraform.tfvars` para o Secret Manager

O workflow não tem o tfvars no repo (está no .gitignore). Lê do Secret Manager:

```bash
gcloud secrets create terraform_tfvars_production \
  --replication-policy=automatic \
  --project=$PROJECT
gcloud secrets versions add terraform_tfvars_production \
  --data-file=infrastructure/terraform/envs/production/terraform.tfvars \
  --project=$PROJECT
```

Para atualizar (sempre que mudar tfvars local):
```bash
gcloud secrets versions add terraform_tfvars_production \
  --data-file=infrastructure/terraform/envs/production/terraform.tfvars \
  --project=$PROJECT
```

## Como rodar

GitHub UI: **Actions** → **Deploy production (segmented)** → **Run workflow** → escolher `segment` e `dry_run`.

CLI:
```bash
# Dry-run de tenant (mais comum: ver o que mudaria)
gh workflow run deploy.yml -f segment=tenant -f dry_run=true

# Aplicar só rotas (fix de 502), pulando Grafana (nexaduo-app exited)
gh workflow run deploy.yml -f segment=routes -f dry_run=false -f skip_grafana=true

# Pipeline completo, dry-run primeiro
gh workflow run deploy.yml -f segment=all -f dry_run=true
gh workflow run deploy.yml -f segment=all -f dry_run=false

# Re-aplicar só o Chatwoot (envs OAuth, por exemplo)
gh workflow run deploy.yml -f segment=tenant -f tenant_subset=chatwoot -f dry_run=false

# Smoke público (HTTPS reachability + OAuth probe)
gh workflow run deploy.yml -f segment=validate
```

## Limitações conhecidas

1. **`tenant_subset` ainda não funciona end-to-end**. O workflow já gera os
   `-target` corretos no `terraform plan`, mas isso assume que o state do tenant
   está populado. Hoje ele está vazio (ver issue #5). Vai funcionar a partir do
   primeiro `tenant` apply bem-sucedido.

2. **`bootstrap` não é idempotente**. `bootstrap-coolify.sh` foi escrito
   para uma instalação inicial — em re-execuções ele tenta criar o `coolify_url`
   secret de novo. Refatorar pra ser idempotente é trabalho separado.

3. **`grafana` (nexaduo-app) está exited em produção**. O job `routes` é
   resiliente a isso: com `skip_grafana=true` (default), aplica fallback Traefik
   só pra Chatwoot/Dify/Coolify. Quando o Grafana for reanimado, mude para
   `skip_grafana=false` e re-rode.

4. **OAuth ainda não funciona** mesmo com tudo o resto verde — ver issue #5.
   O job `validate` roda `04-oauth.spec.ts`, que **vai falhar deterministicamente
   até a issue ser fechada** — esse é o comportamento esperado e serve como
   regressão guard.

5. **`validate` mede apenas o edge público**. Não roda `health-check-all.sh`
   nem o login Playwright (`03-smoke.spec.ts`) — esses pressupõem Docker local
   e credenciais admin, ambos incompatíveis com runner GH Actions. Para checagem
   container-level, rode esses scripts via SSH na VM ou em CI separado.

## Troubleshooting

### "Permission denied" no terraform apply

Falta role no SA `gh-deployer`. Conferir com:
```bash
gcloud projects get-iam-policy nexaduo-492818 --format=json \
  | jq '.bindings[] | select(.members[] | contains("gh-deployer"))'
```

### "Could not load backend state from gs://..."

`TF_BACKEND_PREFIX_*` errado. O state real está em `terraform/state/foundation`
(não `terraform/foundation`). Conferir lista:
```bash
gcloud storage ls -r gs://nexaduo-terraform-state/terraform/
```

### Job `validate` falha em "Run Playwright OAuth checks"

**Comportamento esperado** enquanto issue #5 não for fechada — o spec
`04-oauth.spec.ts` valida que `/auth/google_oauth2` (Chatwoot) e
`/console/api/oauth/login/google` (Dify) redirecionam até `accounts.google.com`.
Hoje retornam 404 e 400 respectivamente. Quando a issue fechar, esses testes
têm que passar; mantenha-os como regression guard.

## Roadmap (próximas iterações)

- [ ] Adicionar job `image-promote` que move tag `deploy-<run_id>` para `latest` após `validate` passar
- [ ] Slack/Discord notification ao final de `all` com estado de cada job
- [ ] Workflow `rollback.yml` que aplica tag anterior + redeploy tenant
- [ ] Lock concorrência também por `tenant_subset` para permitir 2 services em paralelo
