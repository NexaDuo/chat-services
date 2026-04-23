# Infraestrutura NexaDuo Chat Services (Terraform)

Este diretório contém a definição da infraestrutura como código para o NexaDuo Chat Services, utilizando GCP (Google Cloud Platform) e Cloudflare.

## Estrutura
- `/modules`: Módulos reutilizáveis (VM, DNS, Cloudflare tunnel, GCS, Artifact Registry, WIF publisher).
- `/envs/production/foundation`: Camada base (VPC, VM, Firewall, DNS, Tunnel, Artifact Registry, WIF).
- `/envs/production/tenant`: Camada de aplicação (Stacks do Coolify, Envs).

## Pré-requisitos
1. **Google Cloud SDK**: Autenticado (`gcloud auth application-default login`).
2. **Terraform**: v1.0+.
3. **Token da Cloudflare**: Com permissões de edição de DNS.

## Como Executar (Provisionamento em 3 Passos)

### 1. Configurar Variáveis
Navegue até o diretório de produção e configure o arquivo global de variáveis:

```bash
cd infrastructure/terraform/envs/production
cp terraform.tfvars.example terraform.tfvars
# Edite o arquivo terraform.tfvars com seus dados reais
nano terraform.tfvars
```

### 2. Deploy completo (recomendado)

A forma mais simples de subir o ambiente inteiro é rodar o orquestrador, que executa os 3 passos em sequência e sobrevive ao 409 do provider Coolify:

```bash
./scripts/deploy-production.sh
```

O script executa:
1. `terraform apply` em `envs/production/foundation` (VM, VPC, Tunnel, DNS, bucket de backup, Artifact Registry, SA do GitHub publisher + Workload Identity).
2. `scripts/bootstrap-coolify.sh` (instala Coolify, gera token de API, sincroniza secrets no GCP Secret Manager, configura o credential helper do Artifact Registry na VM — autenticação via SA padrão do Compute, nada de token em disco).
3. `scripts/build-push-images.sh` (build local + push de `middleware` e `self-healing-agent` para o Artifact Registry; pule com `SKIP_IMAGE_BUILD=true` se o workflow de CI já publicou as imagens).
4. `scripts/apply-tenant.sh` (terraform apply em `envs/production/tenant` com retry automático: quando o Coolify devolve `409 Conflict creating service envs`, limpa os envs auto-populados do compose via `scripts/clean-service-envs.sh` e tenta de novo).
5. `scripts/refresh-coolify-routes.sh` (opcional — desative com `REFRESH_ROUTES_AFTER_DEPLOY=false`).

## Artifact Registry e publicação de imagens

As imagens `middleware` e `self-healing-agent` vivem em
`us-central1-docker.pkg.dev/nexaduo-492818/nexaduo/{middleware,self-healing-agent}`.
A foundation cria o repo + a SA `gh-publisher@...` + o Workload Identity
Provider `projects/205245484827/locations/global/workloadIdentityPools/github/providers/nexaduo-chat-services`.

Formas de publicar uma nova versão:

- **CI (recomendado)**: crie uma tag `vX.Y.Z` — o workflow
  `.github/workflows/publish-images.yml` faz build+push via WIF (sem
  secret JSON) e aplica as tags `vX.Y.Z`, `sha-<short>` e `latest`.
- **Local**: `IMAGE_TAG=0.1.0 ./scripts/build-push-images.sh` — útil
  para o primeiro deploy, quando ainda não há tag criada.

A VM não precisa de `docker login`: o credential helper `gcloud` autentica
via metadata server com a default Compute SA, que recebe `roles/artifactregistry.reader`
via binding da foundation.

### 3. Deploy manual passo a passo

Caso queira rodar os passos isoladamente:

```bash
# Passo 1 — Fundação
cd infrastructure/terraform/envs/production/foundation
terraform init -backend-config="bucket=nexaduo-terraform-state" -backend-config="prefix=terraform/foundation"
terraform apply -var-file=../terraform.tfvars

# Passo 2 — Bootstrap do Coolify
cd ../../../../..
./scripts/bootstrap-coolify.sh

# Passo 3 — Tenant (use o wrapper para tratar o 409 do Coolify)
./scripts/apply-tenant.sh
```

## Como Destruir (Em 2 Passos)

Para evitar erros de conexão, a destruição deve seguir a ordem inversa:

1. **Remover Aplicações (Tenant)**:
   ```bash
   cd infrastructure/terraform/envs/production/tenant
   terraform destroy -var-file=../terraform.tfvars
   ```

2. **Remover Infraestrutura (Foundation)**:
   ```bash
   cd infrastructure/terraform/envs/production/foundation
   terraform destroy -var-file=../terraform.tfvars
   ```

## Acesso e Verificação
- **Acesso SSH (via IAP)**:
  ```bash
  gcloud compute ssh nexaduo-chat-services --tunnel-through-iap
  ```
- **Verificação E2E**:
  ```bash
  ./scripts/verify-v1-e2e.sh
  ```
