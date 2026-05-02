# Scripts operacionais

Este diretório contém utilitários para gerenciamento, deploy e manutenção da stack NexaDuo.

## Deploy de Produção

### `deploy-production.sh`
O orquestrador principal. Gerencia a execução do Terraform para a fundação e chama os scripts de bootstrap e deploy de aplicação.

### `deploy-tenant-direct.sh`
O motor de deploy da camada de aplicação. Transfere arquivos `docker-compose.yml` e `.env` (populado com segredos do GCP) via SCP e executa o comando de subida via SSH na VM.

### `bootstrap-coolify.sh`
Configura a VM recém-criada: instala o Coolify, gera tokens de API iniciais e sincroniza os segredos necessários para o GCP Secret Manager.

### `refresh-coolify-routes.sh`
Utilitário para forçar a atualização das rotas do Traefik no Coolify. Essencial quando novos containers são criados e o proxy dinâmico não os detecta automaticamente.

## Manutenção e Backup

### `backup.sh`
Executa `pg_dump` de todos os databases do stack (`chatwoot`, `dify`, `dify_plugin`, `evolution`) via `docker compose exec` e armazena em `./backups/` (ou `$BACKUP_DIR`).

### `generate-env.sh`
Gera o arquivo `.env` a partir do `.env.example`, preenchendo segredos aleatórios e uma senha robusta para o Chatwoot.

## Validação

### `validate-stack.sh`
Script unificado para ambiente local. Derruba a stack atual, limpa volumes, sobe novamente, aguarda health check, roda onboarding e executa testes smoke.

### `health-check-all.sh`
Verifica a disponibilidade de todos os endpoints da stack em produção.
