# Infraestrutura NexaDuo Chat Services (Terraform)

Este diretório contém a definição da infraestrutura como código para o NexaDuo Chat Services, utilizando GCP (Google Cloud Platform) e Cloudflare.

## Estrutura
- `/modules`: Módulos reutilizáveis (VM, DNS).
- `/envs/production/foundation`: Camada base (VPC, VM, Firewall, DNS).
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
1. `terraform apply` em `envs/production/foundation` (VM, VPC, Tunnel, DNS, bucket de backup).
2. `scripts/bootstrap-coolify.sh` (instala Coolify, gera token de API, sincroniza secrets no GCP Secret Manager, faz login no GHCR, cria a docker network).
3. `scripts/apply-tenant.sh` (terraform apply em `envs/production/tenant` com retry automático: quando o Coolify devolve `409 Conflict creating service envs`, limpa os envs auto-populados do compose via `scripts/clean-service-envs.sh` e tenta de novo).
4. `scripts/refresh-coolify-routes.sh` (opcional — desative com `REFRESH_ROUTES_AFTER_DEPLOY=false`).

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
