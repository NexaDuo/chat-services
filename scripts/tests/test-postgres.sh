#!/usr/bin/env bash
# W13: the pinned Postgres image and the backup/restore path, on throwaway
# containers only. Requires Docker/Compose, jq, openssl and GNU timeout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(docker compose --env-file /dev/null -f "$ROOT/deploy/docker-compose.shared.yml" \
  config --format json 2>/dev/null | jq -er '.services.postgres.image')
# Major 16 and an exact pgvector release, pinned by index digest.
[[ $image =~ ^pgvector/pgvector:[0-9]+\.[0-9]+\.[0-9]+-pg16@sha256:[a-f0-9]{64}$ ]]
want_vector=${image#pgvector/pgvector:}; want_vector=${want_vector%%-pg16*}
docker pull "$image" >/dev/null
name="w13-postgres-$(cat /proc/sys/kernel/random/uuid)"
export PGPASSWORD_TEST="$(openssl rand -hex 24)"
cleanup() {
  local status=$?
  trap - EXIT
  timeout 10s docker rm -fv "$name-src" "$name-dst" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start() { # container suffix
  docker run -d --name "$name-$1" --network none -e POSTGRES_PASSWORD="$PGPASSWORD_TEST" \
    -v "$ROOT/infrastructure/postgres/01-init.sql:/docker-entrypoint-initdb.d/01-init.sql:ro" \
    "$image" >/dev/null
  # TCP, not the socket: the image's init phase runs a socket-only server first.
  for _ in $(seq 1 60); do
    docker exec "$name-$1" pg_isready -q -h 127.0.0.1 -U postgres && return 0
    sleep 1
  done
  echo "FAIL: $1 did not become ready" >&2; return 1
}
q() { docker exec -i "$name-$1" psql -v ON_ERROR_STOP=1 -U postgres -d "$2" -At "${@:3}"; }

start src
version=$(q src postgres -c 'show server_version')
[[ $version == 16.* ]] || { echo "FAIL: server_version $version" >&2; exit 1; }
# The versioned init script must have created every application database.
for db in chatwoot dify dify_plugin evolution middleware self_healing; do
  [[ "$(q src postgres -c "select 1 from pg_database where datname='$db'")" == 1 ]] \
    || { echo "FAIL: 01-init.sql did not create $db" >&2; exit 1; }
done
[[ "$(q src postgres -c "select default_version from pg_available_extensions where name='vector'")" == "$want_vector" ]] \
  || { echo "FAIL: image does not ship pgvector $want_vector" >&2; exit 1; }

# A vector table with an HNSW index, a sequence and a constraint: what a dump
# must carry across.
q src dify >/dev/null <<'SQL'
create extension if not exists vector;
create table w13_items (id bigserial primary key, label text not null unique, embedding vector(3) not null);
insert into w13_items (label, embedding)
  select 'item-' || g, array[g, g * 2, g * 3]::vector from generate_series(1, 200) g;
create index w13_items_hnsw on w13_items using hnsw (embedding vector_l2_ops);
SQL
nearest="select string_agg(label, ',' order by d) from (select label, embedding <-> '[10,20,30]' as d from w13_items order by d limit 5) t"
src_nearest=$(q src dify -c "$nearest")
[[ $src_nearest == item-10,* ]] || { echo "FAIL: unexpected nearest neighbours: $src_nearest" >&2; exit 1; }

# Same flags as scripts/backup-host.sh; fail if that script changes them.
grep -q 'pg_dump -U "$POSTGRES_USER" -d "$DB" --no-owner --clean --if-exists' "$ROOT/scripts/backup-host.sh" \
  || { echo "FAIL: backup-host.sh pg_dump invocation changed; review this test" >&2; exit 1; }
start dst
docker exec "$name-src" pg_dump -U postgres -d dify --no-owner --clean --if-exists \
  | q dst dify >/dev/null

[[ "$(q dst dify -c "select extversion from pg_extension where extname='vector'")" == "$want_vector" ]]
[[ "$(q dst dify -c 'select count(*) from w13_items')" == 200 ]]
[[ "$(q dst dify -c "$nearest")" == "$src_nearest" ]]
[[ "$(q dst dify -c "select count(*) from pg_indexes where indexname='w13_items_hnsw' and indexdef like '%hnsw%'")" == 1 ]]
# The sequence continues after the restore and the unique constraint holds.
[[ "$(q dst dify -c "insert into w13_items (label, embedding) values ('after', '[1,1,1]') returning id" | head -n 1)" == 201 ]]
if q dst dify -c "insert into w13_items (label, embedding) values ('after', '[1,1,1]')" >/dev/null 2>&1; then
  echo "FAIL: unique constraint lost in restore" >&2; exit 1
fi
echo "PASS: Postgres $version with pgvector $want_vector; init script, dump/restore, HNSW index, sequence and constraint"
