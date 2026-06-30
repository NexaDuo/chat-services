#!/usr/bin/env bash
# =============================================================================
# backup-local.sh — Daily backup for the stack now that it runs locally.
#
# Replaces the GCS pg_dump cron that lived on the (now decommissioned) GCP VM.
# Crucially, this backs up BOTH:
#   1. all 7 Postgres databases (pg_dump --clean --if-exists, gzipped), AND
#   2. the Docker VOLUMES that are NOT in the DB — especially Dify's RSA
#      privkey (dify-api-storage), whose loss cost us the Azure creds on
#      2026-06-29. See AGENTS.md "pg_dump is NOT a full backup".
#
# Default destination is the OneDrive folder (offsite/synced). Override with
# BACKUP_DEST=/some/path. Keeps the last KEEP_DAYS (default 14) dated folders.
#
# Usage:   scripts/backup-local.sh
# Cron:    0 3 * * *  /home/ubuntu-24/repos/NexaDuo/chat-services/scripts/backup-local.sh >> /tmp/nexaduo-backup.log 2>&1
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

BACKUP_DEST="${BACKUP_DEST:-/mnt/c/Users/alexandre-machado/OneDrive/Projetos/NexaDuo/local-backups}"
KEEP_DAYS="${KEEP_DAYS:-14}"
STAMP="$(date +%Y-%m-%d-%H%M)"
OUT="$BACKUP_DEST/$STAMP"

DBS=(chatwoot dify dify_plugin evolution middleware self_healing grafana)
VOLS=(dify-api-storage dify-plugin-storage chatwoot-storage chatwoot-public evolution-instances)

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

PG="$(docker ps --filter name=postgres --format '{{.Names}}' | grep -E 'postgres' | head -1)"
[ -n "$PG" ] || { echo "[err] postgres container not running"; exit 1; }

mkdir -p "$OUT/db" "$OUT/volumes"
log "Backup -> $OUT"

# 1) Postgres dumps
for db in "${DBS[@]}"; do
  if docker exec "$PG" pg_dump -U postgres --clean --if-exists "$db" 2>/dev/null | gzip > "$OUT/db/${db}.sql.gz"; then
    [ -s "$OUT/db/${db}.sql.gz" ] && log "db $db ($(du -h "$OUT/db/${db}.sql.gz" | cut -f1))" || echo "[warn] $db dump empty"
  else echo "[warn] $db dump failed"; fi
done
# fail loudly if the critical DBs are missing/empty (matches vm-backup.sh contract)
for crit in chatwoot middleware; do
  [ -s "$OUT/db/${crit}.sql.gz" ] || { echo "[err] critical DB $crit not dumped"; exit 1; }
done

# 2) Docker volumes (the part pg_dump misses)
for v in "${VOLS[@]}"; do
  vol="${COMPOSE_PROJECT_NAME:-nexaduo}_${v}"
  if docker volume inspect "$vol" >/dev/null 2>&1; then
    docker run --rm -v "$vol":/data -v "$OUT/volumes":/backup alpine tar czf "/backup/${v}.tgz" -C /data . 2>/dev/null \
      && log "vol $v ($(du -h "$OUT/volumes/${v}.tgz" | cut -f1))" || echo "[warn] vol $v tar failed"
  else echo "[warn] volume $vol not found"; fi
done

# 3) prune old backups
if [ -d "$BACKUP_DEST" ]; then
  find "$BACKUP_DEST" -maxdepth 1 -type d -name '20*' -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
fi
log "Backup done. Total: $(du -sh "$OUT" | cut -f1)"
