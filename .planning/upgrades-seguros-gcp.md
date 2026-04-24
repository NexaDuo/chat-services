# Plano de Atualização Segura da Stack (GCP)

## 🎯 Objetivo
Garantir que atualizações de versão da stack ou do middleware ocorram sem risco de perda de dados nos bancos de dados (Postgres/Redis) rodando no GCP.

## 🛡️ Estratégias de Proteção

### 1. Persistência de Dados (Docker Volumes)
*   **Volumes Nomeados:** A stack utiliza volumes nomeados (ex: `postgres-data`). O Coolify/Docker preserva esses volumes entre deploys, a menos que o comando `docker compose down -v` seja executado explicitamente.
*   **Risco Local vs Produção:** Nunca utilizar a flag `-v` em produção.
*   **Long-term:** Planejar a migração para **GCP Cloud SQL** para separar totalmente o ciclo de vida dos dados da VM.

### 2. Automação de Backups (GCS)
*   **Script:** `scripts/backup.sh` já está configurado para realizar `pg_dump`.
*   **Destino:** Google Cloud Storage (GCS) via variável `BACKUP_GCS_BUCKET`.
*   **Frequência:** Diário via Cron e **Sempre** antes de um deploy de infraestrutura (`apply-tenant.sh`).

### 3. Redundância de Infraestrutura
*   **VM Snapshots:** Ativar snapshots agendados no GCP para o disco da instância `nexaduo-chat-services`.
*   **Rollback de Imagens:** Utilizar tags semânticas (ex: `v1.2.3`) no Artifact Registry. Evitar o uso de `latest` para facilitar o rollback imediato em caso de falha no middleware.

### 4. Fluxo de Deploy Seguro
1.  Validar localmente com a suite de testes em `onboarding/`.
2.  Executar backup manual: `./scripts/backup.sh`.
3.  Executar o deploy via Terraform/Coolify.
4.  Monitorar logs do `self-healing-agent` para detecção precoce de anomalias.
