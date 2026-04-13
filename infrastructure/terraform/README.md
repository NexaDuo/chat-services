# Infraestrutura NexaDuo Chat Services (Terraform)

Este diretório contém a definição da infraestrutura como código para o NexaDuo Chat Services, utilizando GCP (Google Cloud Platform) e Cloudflare.

## Estrutura
- `/modules`: Módulos reutilizáveis (VM, DNS).
- `/envs/production`: Configuração do ambiente de produção.

## Pré-requisitos
1. **Google Cloud SDK**: Instalado e autenticado (`gcloud auth application-default login`).
2. **Terraform**: Instalado (v1.0+).
3. **Token da Cloudflare**: Com permissões de edição de DNS.

## Como Executar

### 1. Configurar Variáveis
Navegue até o diretório de produção e configure suas credenciais:

```bash
cd infrastructure/terraform/envs/production
cp terraform.tfvars.example terraform.tfvars
# Edite o arquivo terraform.tfvars com seus dados reais
nano terraform.tfvars
```

### 2. Inicializar
Baixa os providers e inicializa os módulos:

```bash
terraform init \
    -backend-config="bucket=nexaduo-terraform-state" \
    -backend-config="prefix=terraform/state"
```

### 3. Planejar
Verifica o que será criado/alterado antes de aplicar:

```bash
terraform plan
```

### 4. Aplicar
Cria a infraestrutura na nuvem:

```bash
terraform apply
```

### 5. Verificar Acesso (via IAP)
A porta SSH (22) está restrita ao Identity-Aware Proxy do Google. Para acessar a VM, utilize o comando `gcloud`:

```bash
gcloud compute ssh nexaduo-chat-services --tunnel-through-iap --project <PROJECT_ID> --zone us-central1-a
```

### 6. Instalação Manual do Coolify (Se necessário)
Se o script de inicialização falhar, você pode instalar manualmente via SSH:

```bash
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
```

---
**Nota:** Para destruir a infraestrutura e evitar custos: `terraform destroy`

