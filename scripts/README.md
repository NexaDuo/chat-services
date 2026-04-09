# Scripts operacionais

## `backup.sh`

Executa `pg_dump` de todos os databases do stack (`chatwoot`, `dify`, `dify_plugin`, `evolution`) via `docker compose exec` e armazena em `./backups/` (ou `$BACKUP_DIR`).

### Uso

```bash
./scripts/backup.sh                         # dump + rotação de 14 dias
BACKUP_DIR=/opt/backups ./scripts/backup.sh # destino customizado
BACKUP_KEEP_DAYS=30 ./scripts/backup.sh     # retenção maior
```

### Agendar via cron no host

```cron
0 3 * * * cd /opt/nexaduo/chat-services && ./scripts/backup.sh >> /var/log/nexaduo-backup.log 2>&1
```

### Restaurar

```bash
# 1. Parar os apps que usam o DB
docker compose stop chatwoot-rails chatwoot-sidekiq dify-api dify-worker evolution-api middleware

# 2. Restaurar
gunzip -c backups/chatwoot-2026-04-08-0300.sql.gz | \
  docker compose exec -T postgres psql -U postgres -d chatwoot

# 3. Religar
docker compose up -d
```

> Dumps usam `--clean --if-exists` → restaurar **sobrescreve** o schema. Faça um snapshot do volume `postgres-data` antes se quiser um rollback rápido.

## TODO

- [ ] Cifrar backups (GPG) antes de enviar para storage remoto (S3/B2).
- [ ] Script `restore.sh` interativo.
- [ ] Healthcheck wrapper (`./scripts/status.sh`) que exibe o estado de todos os containers + filas.
