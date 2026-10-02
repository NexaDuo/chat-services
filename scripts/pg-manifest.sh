#!/usr/bin/env bash
# Print a deterministic manifest of a Postgres server's application data:
# per database, the extensions, every user table with its EXACT row count,
# every sequence with its last value, and index/constraint totals.
#
#   scripts/pg-manifest.sh <container> > before.txt
#
# Two servers hold the same data when their manifests are identical. Used to
# prove a dump/restore across major versions (W14) lost nothing. Counts are
# exact (`count(*)`), so run it with the writers stopped. Read-only.
# NOT NULL constraints are left out: PostgreSQL 18 catalogs them in
# pg_constraint and 16 does not, so they would differ by design.
set -euo pipefail
container=${1:?usage: pg-manifest.sh <postgres container>}
q() { docker exec -i "$container" psql -v ON_ERROR_STOP=1 -U postgres -At -F '|' "$@"; }

# An array, not `for db in $(...)`: a database name must never be word-split
# or glob-expanded by the shell.
mapfile -t dbs < <(q -d postgres -c "select datname from pg_database where not datistemplate and datname <> 'postgres' order by 1" </dev/null)
# A failed listing must not yield an empty manifest that compares equal to
# another empty one.
(( ${#dbs[@]} > 0 )) || { echo "pg-manifest: no application database listed from $container" >&2; exit 1; }
for db in "${dbs[@]}"; do
  echo "== $db"
  q -d "$db" -c "select 'encoding', pg_encoding_to_char(encoding), datcollate, datctype from pg_database where datname = current_database()"
  q -d "$db" -c "select 'extension', extname from pg_extension where extname <> 'plpgsql' order by 2"
  # Versions on their own lines: contrib modules legitimately change version
  # with the server major, so a cross-major comparison drops `extversion|`.
  q -d "$db" -c "select 'extversion', extname, extversion from pg_extension where extname <> 'plpgsql' order by 2"
  # One exact count per user table, generated and executed in a single session.
  q -d "$db" <<'SQL'
select format('select %L, %L, count(*) from %I.%I;', 'table', schemaname || '.' || tablename, schemaname, tablename)
from pg_tables
where schemaname not in ('pg_catalog', 'information_schema')
order by schemaname, tablename
\gexec
SQL
  q -d "$db" -c "select 'sequence', schemaname || '.' || sequencename, coalesce(last_value::text, 'unused') from pg_sequences order by 1, 2"
  q -d "$db" -c "select 'indexes', count(*), count(*) filter (where indexdef ilike '%using hnsw%' or indexdef ilike '%using ivfflat%') from pg_indexes where schemaname not in ('pg_catalog', 'information_schema')"
  q -d "$db" -c "select 'constraints', contype, count(*) from pg_constraint c join pg_namespace n on n.oid = c.connamespace where n.nspname not in ('pg_catalog', 'information_schema') and contype <> 'n' group by contype order by contype"
  q -d "$db" -c "select 'invalid_indexes', count(*) from pg_index where not indisvalid"
done
