#!/usr/bin/env bash
# =============================================================================
# backup.sh — pg_dump diário para os DBs do stack NexaDuo
# -----------------------------------------------------------------------------
# Faz dump comprimido de chatwoot, dify, dify_plugin e evolution. Os arquivos
# vão para $BACKUP_DIR (default: ./backups), com rotação opcional via
# BACKUP_KEEP_DAYS (default: 14).
#
# Agendar via cron no host:
#   0 3 * * * cd /opt/nexaduo/chat-services && ./scripts/backup.sh >> /var/log/nexaduo-backup.log 2>&1
# =============================================================================
set -euo pipefail

: "${BACKUP_DIR:=./backups}"
: "${BACKUP_KEEP_DAYS:=14}"

# Carrega POSTGRES_USER do .env se existir (não falha se .env ausente).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
: "${POSTGRES_USER:?POSTGRES_USER não definido (defina no .env)}"

TS=$(date +%F-%H%M)
mkdir -p "$BACKUP_DIR"

for DB in chatwoot dify dify_plugin evolution; do
  OUT="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  echo "==> Dumping ${DB} → ${OUT}"
  docker compose exec -T postgres \
    pg_dump -U "$POSTGRES_USER" -d "$DB" --no-owner --clean --if-exists \
    | gzip -9 > "$OUT"
done

echo "==> Limpando backups com mais de ${BACKUP_KEEP_DAYS} dias"
find "$BACKUP_DIR" -type f -name '*.sql.gz' -mtime +"$BACKUP_KEEP_DAYS" -print -delete || true

echo "==> Backup concluído em $(date -Is)"
