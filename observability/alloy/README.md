# Docker logs: Alloy (W2b)

The image is `grafana/alloy:v1.20.0` pinned to the multi-platform OCI index
`sha256:f111cce835516c5f99166342be7038496b52ced16667be5a11e19258a3e4cd30`.
Upstream does not publish the unprefixed `1.20.0` tag.

`config.alloy` starts from `alloy convert --source-format=promtail` against the
retained `observability/promtail/promtail.yaml`. The directory mount avoids
single-file inode replacement failures (#113/#116). `ready.sh` uses the image's
Bash/timeout to check HTTP 200 from `/-/ready`; it does not equate TCP with readiness.
No autoheal and no host port publication. The provisional 768MiB cap uses #157's
observability 6x tier with a 128MiB budget; measure RSS under live load before
claiming this sizing is sufficient.

| Promtail | Alloy / Loki contract |
| --- | --- |
| Docker SD, every container, refresh 5s | `discovery.docker`, same scope/interval |
| Docker relabel rules | `discovery.relabel` rules applied **at source**, so `__meta_docker_container_log_stream` exists |
| Container name minus leading `/` | `container`, unchanged |
| Docker stream | `stream=stdout` / `stderr`, unchanged |
| Compose service, then Coolify subName | `service`, Coolify takes precedence when nonempty; fixes legacy empty Coolify value erasing Compose service |
| Compose project / Coolify resourceName | `project` / `resource`, unchanged (absent when unset) |
| Docker, JSON, Rails regex, two level templates | Corresponding `stage.*`; JSON/Pino numeric/Rails levels normalized to uppercase, plain text defaults to INFO |
| Indexed `level`, `method`, `status` | Same labels; no `job` or extra Alloy label added |
| Email replace | Corrected capture replacement to intended `ali***@example.invalid`; legacy `${1}`/`${2}` was inserted literally into each capture |
| No phone/CPF mask | Added formatted Brazilian phone → `[PHONE]`, CPF → `[CPF]`; deliberately not generic numeric matching that would damage IDs |
| `trace_id`, `span_id`, `account_id`, `conversation_id` | `stage.structured_metadata`, never indexed labels; original body remains available |
| No drop/filter rules | Only new drop is the one-hour age guard before parsing |

Grafana's `service`/`level` queries and self-healing's `project`/`service` selector
keep their names and values. Loki may expose structured metadata as fields in a
query response's `stream`; `/loki/api/v1/series` is the check for indexed labels.
The unchanged Loki configuration can also add its own `service_name` label and
`detected_level` metadata.

## Positions and bounded replay

Alloy stores native positions at
`/var/lib/alloy/loki.source.docker.docker/positions.yml` in `alloy-data`. Preserve
the component name and storage path across restarts. Do not copy Promtail's
positions file into that path: the native format/keying differs. Keep
`promtail-data` declared and untouched, together with the legacy config.

The pinned [Docker source implementation](https://github.com/grafana/alloy/blob/v1.20.0/internal/component/loki/source/docker/tailer.go)
has no tail-from-end option. Without native positions it reads retained Docker
buffers. The first process stage drops entries whose **Docker timestamp** is
older than one hour, before parsing or sending them to Loki. Thus disk/CPU
may still read the backlog, but Loki does not receive that backlog. Up to one
hour of overlap can be re-sent on first start/position loss (Loki drops exact
duplicate entries of the same stream). Entries more than one hour old when
collected are intentionally lost, i.e. only after a collector outage longer than
that; one hour covers routine restarts/reboots so incident logs still reach Loki. This is bounded replay,
not exactly-once delivery or a claim to import legacy positions.

## Operator cutover (future live work, after CI gates)

Use `dc()` with the production compose chain in `docs/upgrade-plan-2026-09.md`.
Coordinate the window and prepare both images/config revisions first.

1. With the **old** compose chain still available, `dc stop promtail`. Do this
   before changing revisions: the new chain has no Promtail service.
2. Archive the stopped `promtail-data` positions volume and preserve the old
   config/image reference alongside the fresh validated wave backup. Include
   `promtail-data` with the existing critical volume suffixes in the one-off
   `BACKUP_VOLUME_SUFFIXES` override; do not replace/omit required app archives.
   Never delete/prune a volume. Keep the stopped legacy container for rollback.
3. Switch to the new chain; `dc pull alloy`, then `dc up -d --no-deps alloy`.
   Do **not** run global `run-stack.sh up` (`--remove-orphans`) or bootstrap/restore
   during cutover. Once started, `scripts/run-stack.sh reload-alloy` records the
   checksum and restarts only Alloy if it differs from the last successful load.
4. Confirm Docker health, new Loki logs/labels, PII masks, structured IDs and no
   ingest surge. Run `scripts/run-stack.sh validate`, `scripts/health-check-all.sh`
   and onboarding `npm run test:all` against the real URLs. Observe OOM/restarts,
   ingestion/duplicates and the next load/backup cycle. Remove only the stopped
   Promtail container after validation; retain its positions volume.
5. Future config edits: `run-stack.sh reload-alloy` is checksum gated; ordinary
   `up`/greenfield `bootstrap` also invokes it. The marker is written only after
   restart succeeds. The legacy Coolify bootstrap checksum path also names Alloy.
   The hourly scheduled check remains engine/backup-only; full health checks
   cover Alloy readiness and memory limits.

Rollback: **before reverting the chain**, `dc stop alloy`; return to the saved
Promtail config/image and `dc up -d --no-deps promtail`, using the untouched
`promtail-data`. Never run both collectors together. Preserved Promtail positions
can replay the cutover interval and duplicate logs already sent by Alloy. Retain
`alloy-data` for investigation/retry; do not delete either volume.

## Synthetic CI

`bash scripts/tests/test-alloy-config.sh` checks checksum no-op/retry semantics
without Docker. `bash scripts/tests/test-alloy.sh` has a 105s work deadline plus
bounded cleanup (<120s), unique resource names and no production mounts/data.
It uses pinned Alloy and the repository's pinned Loki, real configuration,
Compose/Coolify fixture emitters and a read-only Docker API proxy exposing only
those fixture IDs. The proxy backdates a synthetic sentinel Docker frame to
exercise the backlog guard. It checks masking, labels, metadata versus the index,
readiness, positions and restart. No browser flow changes: Playwright regression
N/A. This does not substitute for the future live cutover checks above.
