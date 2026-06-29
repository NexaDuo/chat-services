#!/usr/bin/env bash
# =============================================================================
# vm-backup.sh — pg_dump diário dos DBs do stack NexaDuo, rodando NA VM.
# -----------------------------------------------------------------------------
# Diferente do scripts/backup.sh (variante local-dev, que usa `docker compose
# exec`), este script roda direto no host de produção, onde o Postgres é um
# container gerenciado pelo Coolify com nome dinâmico (postgres-<uuid>). Ele:
#   - descobre o container Postgres e os DBs dinamicamente (sem hardcode);
#   - faz dump comprimido de cada DB em $BACKUP_DIR;
#   - rotaciona localmente por $BACKUP_KEEP_DAYS;
#   - envia para gs://$BACKUP_BUCKET via `gcloud storage cp` (a VM SA tem escopo
#     cloud-platform; a retenção remota fica por conta do lifecycle do bucket).
#
# Instalado em /opt/nexaduo/vm-backup.sh pelo bootstrap-coolify.sh (seção 3e),
# agendado via cron do root:
#   0 3 * * * BACKUP_BUCKET=<bucket> /opt/nexaduo/vm-backup.sh >> /var/log/nexaduo-backup.log 2>&1
# =============================================================================
set -euo pipefail

: "${BACKUP_DIR:=/opt/nexaduo/backups}"
: "${BACKUP_KEEP_DAYS:=14}"
: "${POSTGRES_USER:=postgres}"
: "${BACKUP_BUCKET:?BACKUP_BUCKET não definido (ex: nexaduo-coolify-backups)}"

log() { echo "[$(date -Is)] $*"; }

# 1. Localiza o container Postgres (nome dinâmico do Coolify: postgres-<uuid>).
PG="$(docker ps --filter 'name=^/postgres-' --format '{{.Names}}' | head -n1)"
if [[ -z "$PG" ]]; then
  # Fallback: por imagem (pgvector/postgres).
  PG="$(docker ps --filter 'ancestor=pgvector/pgvector' --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$PG" ]]; then
  log "ERRO: container Postgres não encontrado (docker ps --filter name=^/postgres-)."
  exit 1
fi
log "Container Postgres: $PG"

# 2. Descobre os DBs de aplicação (exclui os internos do Postgres).
mapfile -t DBS < <(docker exec "$PG" psql -U "$POSTGRES_USER" -tAc \
  "SELECT datname FROM pg_database WHERE datname NOT IN ('postgres','template0','template1') ORDER BY datname")
if [[ ${#DBS[@]} -eq 0 ]]; then
  log "ERRO: nenhum DB de aplicação encontrado."
  exit 1
fi
log "DBs a backupar: ${DBS[*]}"

TS="$(date +%F-%H%M)"
HOSTTAG="$(hostname -s)"
mkdir -p "$BACKUP_DIR"

# 3. Dump por DB.
FILES=()
for DB in "${DBS[@]}"; do
  OUT="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  log "==> Dumping ${DB} → ${OUT}"
  docker exec "$PG" pg_dump -U "$POSTGRES_USER" -d "$DB" --no-owner --clean --if-exists \
    | gzip -9 > "$OUT"
  FILES+=("$OUT")
done

# 4. Rotação local.
log "==> Limpando backups locais com mais de ${BACKUP_KEEP_DAYS} dias"
find "$BACKUP_DIR" -type f -name '*.sql.gz' -mtime +"$BACKUP_KEEP_DAYS" -print -delete || true

# 5. Upload para GCS (append; retenção remota via lifecycle do bucket).
log "==> Enviando para gs://${BACKUP_BUCKET}/${HOSTTAG}/"
gcloud storage cp "${FILES[@]}" "gs://${BACKUP_BUCKET}/${HOSTTAG}/"

# 6. Verificação de cobertura: os DBs CRÍTICOS (dados de cliente) precisam ter
# sido dumpados com tamanho plausível. Roda DEPOIS do upload (envia o que tiver)
# mas SAI com erro se faltar algo — assim a falha fica visível no log do cron.
# Salvaguarda contra um futuro regression onde um DB crítico (ex: chatwoot)
# pare de ser dumpado silenciosamente (ver incidente 2026-06-25).
CRITICAL_DBS=(${BACKUP_REQUIRED_DBS:-chatwoot middleware})
MIN_BYTES="${BACKUP_MIN_BYTES:-1000}"
missing=0
for DB in "${CRITICAL_DBS[@]}"; do
  f="${BACKUP_DIR}/${DB}-${TS}.sql.gz"
  if [[ ! -f "$f" ]]; then
    log "ERRO: DB crítico '${DB}' NÃO foi dumpado (arquivo ausente). Existe no Postgres?"
    missing=1
    continue
  fi
  sz="$(stat -c%s "$f" 2>/dev/null || echo 0)"
  if [[ "$sz" -lt "$MIN_BYTES" ]]; then
    log "ERRO: dump de '${DB}' suspeito (${sz} bytes < ${MIN_BYTES})."
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  log "==> FALHA: cobertura de backup incompleta para DBs críticos (${CRITICAL_DBS[*]})."
  exit 1
fi

log "==> Backup concluído (${#FILES[@]} DBs; críticos OK: ${CRITICAL_DBS[*]})."
