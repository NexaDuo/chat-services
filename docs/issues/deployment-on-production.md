# Deploy em Produção — Problemas e Soluções

## Estado atual (2026-04-19)
- VM rodando: `136.115.211.240`
- Coolify: healthy, mas token desatualizado no Secret Manager
- Tunnel Cloudflare: configurado e funcional
- Serviços Coolify (nexaduo-shared, chatwoot, dify, nexaduo-app): **não deployados ainda**

---

## Problemas corrigidos no código

### 1. Redis — argumento inválido no comando
**Arquivo:** `deploy/docker-compose.shared.yml`

O formato YAML lista passava `--requirepass VALUE` como um único argumento para o redis-server. Corrigido separando em itens distintos:
```yaml
# ANTES (errado)
- --requirepass ${REDIS_PASSWORD}

# DEPOIS (correto)
- --requirepass
- ${REDIS_PASSWORD}
```

### 2. Postgres init SQL — path relativo não funciona no Coolify
**Arquivo:** `deploy/docker-compose.shared.yml`

O Coolify recebe o compose como string e não tem acesso ao arquivo `./01-init.sql`. Corrigido para path absoluto:
```yaml
# ANTES
- ./01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro

# DEPOIS
- /opt/nexaduo/postgres/01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro
```
O arquivo é enviado para a VM via `gcloud compute scp --tunnel-through-iap` por um `null_resource` no Terraform.

### 3. Cloudflare Tunnel — bypass do Traefik quebrava WebSockets
**Arquivo:** `infrastructure/terraform/modules/cloudflare-tunnel/main.tf`

`chat` e `dify` apontavam diretamente para os containers, ignorando o Traefik. WebSockets (Action Cable do Chatwoot) falhavam. Corrigido para rotear tudo pelo IP público da VM na porta 80:
```hcl
# ANTES
service = "http://nexaduo-chatwoot-rails:3000"

# DEPOIS
service = "http://${var.vm_ip}:80"  # via Traefik
```

---

## Problema estrutural: deploy não é reproduzível

### Causa raiz
O Coolify é instalado do zero a cada nova VM. A cada instalação:
- Um novo **API token** é gerado
- Um novo **destination_uuid** é atribuído ao servidor

O Terraform usa esses valores via GCP Secret Manager, mas eles ficam desatualizados após cada recriação.

### Solução proposta: 3 fases + script bootstrap

**Fase 1 — Infraestrutura (Terraform targets)**
```bash
terraform apply -auto-approve \
  -target=module.vm \
  -target=module.tunnel \
  -target=module.dns_chat \
  -target=module.dns_dify \
  -target=module.backup_storage
```

**Fase 2 — Bootstrap Coolify (`scripts/bootstrap-coolify.sh`)**
Script que deve:
1. Aguardar `http://VM_IP:8000/api/v1/version` responder (poll com retry)
2. Usar as credenciais padrão do Coolify para gerar um API token via API
3. Capturar o `destination_uuid` do servidor local
4. Atualizar ambos no GCP Secret Manager:
   ```bash
   echo -n "$TOKEN" | gcloud secrets versions add coolify_api_token \
     --project nexaduo-492818 --data-file=-
   echo -n "$UUID" | gcloud secrets versions add coolify_destination_uuid \
     --project nexaduo-492818 --data-file=-
   ```
5. Enviar `01-init.sql` para a VM via IAP com retry (IAP leva ~30s para registrar a instância)
6. Criar a rede Docker: `docker network create nexaduo-network`

**Fase 3 — Serviços Coolify**
```bash
terraform apply -auto-approve
```

**Orquestrador: `scripts/deploy-production.sh`**
```bash
#!/bin/bash
set -e
cd infrastructure/terraform/envs/production
terraform apply -auto-approve -target=module.vm -target=module.tunnel \
  -target=module.dns_chat -target=module.dns_dify -target=module.backup_storage
../../scripts/bootstrap-coolify.sh
terraform apply -auto-approve
```

---

## Ação imediata para unbloquear HTTP 404 nas FQDNs

Quando `chat.nexaduo.com`, `dify.nexaduo.com` e `coolify.nexaduo.com` retornam 404 mesmo com containers saudáveis e `service_applications.fqdn` preenchido no banco do Coolify, execute:

```bash
./scripts/refresh-coolify-routes.sh
```

O script:
1. Localiza os containers reais do Chatwoot, Dify e Coolify via labels `coolify.service.subName`.
2. Gera `/data/coolify/proxy/dynamic/nexaduo-routes.yaml` com roteamento explícito por `Host(...)`.
3. Reinicia `coolify-proxy`.
4. Valida rota local (`Host` header) e URLs públicas HTTPS.

Se quiser customizar projeto/zona/VM/domínio:

```bash
PROJECT_ID=nexaduo-492818 \
ZONE=us-central1-b \
VM_NAME=nexaduo-chat-services \
BASE_DOMAIN=nexaduo.com \
./scripts/refresh-coolify-routes.sh
```

---

## Bug conhecido: Coolify provider v0.10.2

O provider `SierraJC/coolify v0.10.2` retorna 422 ao tentar atualizar um serviço existente porque inclui campos read-only (`server_uuid`, `project_uuid`, etc.) no body do request.

**Workaround aplicado:** `ignore_changes = [compose]` no `coolify_service.shared`. Alterações no compose do stack shared devem ser aplicadas manualmente pelo Coolify UI.

---

*Última atualização: 2026-04-19*
