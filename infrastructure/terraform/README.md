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

A forma mais simples de subir o ambiente inteiro é rodar o orquestrador, que gerencia a fundação via Terraform e a aplicação via scripts diretos:

```bash
./scripts/deploy-production.sh
```

O script executa:
1. `terraform apply` em `envs/production/foundation` (VM, VPC, Tunnel, DNS, bucket de backup, Artifact Registry, SA do GitHub publisher + Workload Identity).
2. `scripts/bootstrap-coolify.sh` (instala Coolify, gera token de API, sincroniza secrets no GCP Secret Manager).
3. `scripts/build-push-images.sh` (build local + push para o Artifact Registry).
4. `scripts/deploy-tenant-direct.sh` (deploy da aplicação via SCP/SSH ignorando o provider instável do Coolify).
5. `scripts/refresh-coolify-routes.sh` (opcional — desative com `REFRESH_ROUTES_AFTER_DEPLOY=false`).

## Como Destruir

Para remover completamente o ambiente:

1. **Remover Aplicações (Manual/SSH)**: Opcional, já que a destruição da VM limpa tudo.
2. **Remover Infraestrutura (Foundation)**:
   ```bash
   cd infrastructure/terraform/envs/production/foundation
   terraform destroy -var-file=../terraform.tfvars
   ```

> Nota: A camada `envs/production/tenant` foi mantida apenas para referência histórica de IDs, mas o gerenciamento ativo foi movido para o script `deploy-tenant-direct.sh` devido a limitações do provider Terraform.

## Acesso e Verificação
- **Acesso SSH (via IAP)**:
  ```bash
  gcloud compute ssh nexaduo-chat-services --tunnel-through-iap
  ```
- **Verificação E2E**:
  ```bash
  ./scripts/verify-v1-e2e.sh
  ```
