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

### 2. Passo 1: Fundação (Foundation)
Cria a VM e toda a infraestrutura de rede.

```bash
cd foundation
terraform init -backend-config="bucket=nexaduo-terraform-state" -backend-config="prefix=terraform/foundation"
terraform apply -var-file=../terraform.tfvars
```

### 3. Passo 2: Bootstrap do Coolify
Este script aguarda a VM ficar online, instala o Coolify (se necessário) e gera o token de API necessário para o próximo passo.

```bash
cd ../../../.. # Raiz do projeto
./scripts/bootstrap-coolify.sh
```

### 4. Passo 3: Aplicação (Tenant)
Provisiona as stacks de serviço (Chatwoot, Dify, etc) dentro do Coolify.

```bash
cd infrastructure/terraform/envs/production/tenant
terraform init -backend-config="bucket=nexaduo-terraform-state" -backend-config="prefix=terraform/tenant"
terraform apply -var-file=../terraform.tfvars
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
