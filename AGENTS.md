# Chat Services — Agent Instructions & Lessons Learned

Single source of truth for agents working in this repo. This is a **fully
implemented** production-grade stack; authority on implementation details lies in
the source code and this file.

> **Historical/cloud material** (the decommissioned GCP + Coolify era) lives in
> [`docs/LEGACY-GCP.md`](docs/LEGACY-GCP.md) — archived reference only, do not act
> on it for the running stack.

## Architecture
Four-service stack with **Chatwoot as the single hub** for all conversations:

```
WhatsApp ─▶ Evolution API ─▶ Chatwoot (Webhook) ─▶ Middleware (Adapter) ─▶ Dify ─▶ Azure OpenAI
                                   ▲                       │
                                   └──────── response ─────┘
```

- **Chatwoot** — [chat.nexaduo.com](https://chat.nexaduo.com). Inbox, CRM, ticketing,
  human handoff. Single source of truth.
- **Dify** — [dify.nexaduo.com](https://dify.nexaduo.com). Agentic engine + RAG.
- **Evolution API v2.1+** — **WhatsApp-only** bridge (no Instagram support in any
  version; Instagram is Chatwoot's native channel via Meta OAuth — issue #31).
- **Middleware (Adapter)** — Node/TS: translates Chatwoot webhooks → Dify API calls,
  sends responses back, and is the centralized config provider for internal agents.
- **Self-Healing Agent** — analyzes Loki logs via Dify to find root causes.
- **Observability** — Loki, Promtail, Prometheus, Grafana.
- **Postgres 16+** (shared, separate DBs) + **pgvector** (primary vector store);
  **Redis 7+** (Sidekiq + Celery). **Azure OpenAI** — `gpt-4o` + `gpt-4o-mini`.

**Human handoff** is a Dify tool (HTTP) that sets the Chatwoot conversation to `open`
and adds the `atendimento-humano` label.

## Deployment — host-local Docker Compose behind the Cloudflare tunnel
> **GCP is decommissioned (`b02aa74`).** No cloud VM, no Secret Manager, no GCS/WIF.
> The GitHub Actions `deploy.yml`/`power.yml` are GCP-bound and **dead** (kept as
> `workflow_dispatch`-only stubs). The **only** running environment is the host-local
> stack, which **is** production — there is no separate staging. See issue #109.

The full four-service stack runs as Docker Compose on a single host (a WSL machine,
~31GB RAM) and is served on the production domains
(`chat`/`dify`/`evolution`/`middleware`/`grafana.nexaduo.com`) through the production
**Cloudflare tunnel** (`1eea65b4`, ingress → `coolify-proxy:80`).

Reproducible bootstrap (no manual drift — issue #109):
1. **Inputs (operator-provided, NOT in git):**
   - `./.env` — real production secrets (incl. `CHATWOOT_FRONTEND_URL=https://chat.nexaduo.com`
     and `TUNNEL_TOKEN`). Keys documented in `.env.production.example`. **The root
     `.env` is what the live stack loads — NOT `deploy/.env`** (a dev file whose
     `localhost:3000` default `run-stack.sh preflight` refuses).
   - `$DUMPS_DIR` (`~/nexaduo-local/dumps`) — the `pg_dump` set to restore. Prefer the
     last-good `*-2026-06-25-0300.sql.gz` (memory `prod-data-loss-2026-06-25`).
2. **Bootstrap:** `scripts/run-stack.sh bootstrap` (= `preflight` + `up` + `restore`)
   brings up the stack + proxy + tunnel from the committed compose chain
   (`deploy/docker-compose.{shared,chatwoot,dify,nexaduo}.yml` + root
   `docker-compose.yml` + `deploy/docker-compose.localproxy.yml`).
3. **Routing:** Traefik **Docker provider** reads the committed `traefik.*` router
   labels. File-provider fallback (for flaky Docker-provider hosts, e.g. WSL) is at
   `deploy/traefik/dynamic.yml` and mirrors the labels 1:1.
4. **Validate:** `scripts/run-stack.sh validate` smoke-tests the real tunnel URLs and
   runs the Playwright connectivity + tenant-resolution suites against them.
5. **Backup:** `scripts/backup-host.sh` (daily 03:00 cron via `run-stack.sh
   install-cron`).
6. **Host ports (optional isolation — #119):** `scripts/run-stack.sh --isolated up`
   (or `ISOLATED=1`) publishes **zero** host ports (via
   `deploy/docker-compose.isolated.yml`, `!reset []` merge — Compose 2.24.4+). Public
   traffic still flows via the tunnel → Traefik; service-to-service uses the Docker
   network by container name (never `localhost`/`host.docker.internal`). Local debug
   is via `docker exec` (e.g. `docker exec -it nexaduo-postgres-1 psql -U postgres`).

## Configuration model (hybrid)
1. **Static (.env):** infrastructure secrets (DB passwords, Redis URLs, etc.).
2. **Dynamic (Postgres + Middleware API):** app settings + API keys (e.g.
   `DIFY_SELF_HEALING_API_KEY`).

Internal agents (e.g. `self-healing`) fetch their functional config from the
**Middleware Config API** (`GET /config`), authenticated via `Bearer` using
`HANDOFF_SHARED_SECRET`. New keys go in the `middleware.configs` Postgres table.

## Repo layout
```
docker-compose.yml            # Base stack
/deploy                       # Multi-stack compose configs
/middleware                   # Dify↔Chatwoot adapter (Node/TS)
/infrastructure/postgres      # 01-init.sql: DB creation + pgvector
/infrastructure/terraform     # Foundation IaC (Cloudflare tunnel/DNS live; GCP dead)
/dify-apps                    # DSL (YAML) exports of agents — MUST be versioned
/provisioning /scripts        # Automation + deploy utilities
/onboarding                   # Playwright automation + smoke tests
```

## Reproducibility is non-negotiable
**Every fix lands in code so a from-scratch rebuild reproduces it.** Tearing down and
re-bootstrapping is a safe, acceptable cost — prefer a clean rebuild over accumulating
manual drift.
- **No fix exists until it is in code** (compose/scripts/IaC/schema seeds). A change
  that only lives on the host does not exist for the next bootstrap.
- **Manual host intervention is a stopgap, never the fix** — backfill it into code in
  the same session. Real example that bit us: Promtail config reached the host but a
  running promtail never reloaded it (single-file bind-mount + inode swap) → the change
  went "green" while inert. Fixed by a checksum-gated restart in bootstrap.

## SRE auditor agent
Routine inspections use the workspace skill
[`.agents/skills/sre-auditor/SKILL.md`](.agents/skills/sre-auditor/SKILL.md). Ask it to
"run a routine SRE audit": it runs `scripts/health-check-all.sh`, checks container
states, scans logs for known anomalies, and files structured GitHub issues.

## Operational non-negotiables
- **RAM:** 16 GB minimum for the shared stack.
- **Backup:** daily `pg_dump` (all DBs, `--clean --if-exists`) via
  `scripts/backup-host.sh` (host cron 03:00). Dumps land in `~/nexaduo-local/dumps`
  and, if `BACKUP_RCLONE_REMOTE` is set, are copied **off-host** via rclone (a dump on
  the same host is not a backup). The script verifies critical DBs (`chatwoot`,
  `middleware`) dumped and **fails** otherwise, writing a `.last-success` marker that
  `health-check-all.sh` staleness-checks (fails a health check if the newest dump is
  ≥26h old — silent-failure detection).
  - **`pg_dump` is NOT a full backup.** Critical state lives in Docker volumes no dump
    captures: Dify per-workspace RSA privkeys (encrypt the Azure OpenAI creds → lost =
    `PrivkeyNotFoundError` 500s) and chatwoot-storage uploads (lost = Chatwoot
    `ActiveStorage::FileNotFoundError` 500s on avatars/attachments — issue #61).
    `backup-host.sh` therefore ALSO tars these critical volumes
    (`BACKUP_VOLUME_SUFFIXES`, default `chatwoot-storage dify-api-storage`) into
    `~/nexaduo-local/dumps` as `*<suffix>-<ts>.tar.gz`, rotates + off-host-copies them
    with the dumps, **fails** if a required volume archive is missing/empty, and records
    them in `.last-success`; `health-check-all.sh` staleness-checks the newest archive
    (≥26h ⇒ fail). A DB-only restore leaves dangling `active_storage_blobs` rows whose
    file is gone — `scripts/purge-dangling-blobs.sh` (dry-run by default, `--apply` to
    purge) removes them safely via the ActiveStorage API.
- **Postgres data is SACRED.** It lives in the Docker named volume
  `nexaduo_postgres-data`. **Never** `docker compose down -v` or prune it;
  `run-stack.sh down` deliberately omits `-v`. The host serves production and is shared
  with concurrent work — do **not** recreate the postgres container casually.
- **Observability:** Grafana + Prometheus for queue depths and **token usage per
  account_id**. **Rate limiting:** respect Meta tiers; throttle in Dify.

### Disaster recovery — restore Postgres from a dump (host-local)
Dumps: `~/nexaduo-local/dumps/<db>-<YYYY-MM-DD>-HHMM.sql.gz` (+ off-host mirror if
`BACKUP_RCLONE_REMOTE` set). Last-good production set: `*-2026-06-25-0300.sql.gz`.
`scripts/run-stack.sh restore` automates the loop; by hand for one DB (e.g. `chatwoot`):
1. **Archive current data first** (copy the volume, or a fresh `backup-host.sh` dump).
2. Pick the right dump — verify content (`zcat <dump> | grep <marker>`); a post-incident
   dump may be of an already-empty DB.
3. Stop consumers (`docker stop` the owning containers).
4. Recreate the DB empty (terminate connections, `DROP`+`CREATE`).
5. `zcat <dump> | docker exec -i nexaduo-postgres-1 psql -U postgres -d <db>`.
6. Start consumers; validate row counts + the app via the tunnel (`run-stack.sh validate`).
7. **Remember the Docker volumes** — a dump restore alone leaves `PrivkeyNotFoundError`;
   restore the archived volumes or re-run `flask reset-encrypt-key-pair` + re-enter the
   Azure OpenAI creds.

## Live gotchas
- **Cloudflare SSL loops:** behind the tunnel, disabling `FORCE_SSL` in apps is often
  necessary to prevent infinite redirect loops.
- **Container entrypoints:** images like Chatwoot need explicit entrypoints
  (`docker/entrypoints/rails.sh`) or they default to an interactive shell.
- **No hardcoded localhost in tests:** production tests must use env vars
  (`CHATWOOT_URL`, etc.) to support local + remote validation.
- **Recreate a service without dragging Postgres:** when reapplying a fix to one
  service, recreate **only** that service (`docker compose up -d --no-deps <svc>`) — do
  NOT run an ad-hoc chain that pulls in `nexaduo-postgres-1`. The host is shared and the
  postgres data is SACRED; casual recreation risks concurrent work and the volume.

## Terminology
**NexaDuo is only one tenant** in this multi-tenant stack, not the stack itself. Do not
use "NexaDuo" as a generic name for the platform/dashboard. Call it "Multitenant Chat
Services" or "Omnichannel Stack".

## Release & validation (single environment)
There is **no** staging→prod GitHub Actions pipeline and no separate staging env — the
host-local stack behind the tunnel **is** production (issue #109). Every change
serializes on this live stack; **do not recreate shared containers (especially
`nexaduo-postgres-1`)** and coordinate with concurrent work on the host.
- **CI merge gate (every PR):** `stack-compose-playwright.yml` (job `validate-stack`)
  spins the whole stack up ephemerally on the runner and runs Playwright (Stage 1
  connectivity + Stage 4 tenant resolution). It is the **real** merge gate — monitor it
  to green (`gh run watch`).
- **Mandatory phases (single env):** CI green → apply the merged change to the live
  stack (`scripts/run-stack.sh up`, or recreate only the affected service — never
  `down -v`, never postgres unnecessarily) → validate on the real environment
  (`scripts/run-stack.sh validate` — real tunnel URLs + Playwright) → confirm health
  (`scripts/health-check-all.sh` + inspect the affected `nexaduo-*` containers). If a
  phase genuinely can't run, **say so explicitly** in the PR — don't fake it.
- **Active monitoring:** the task is not done at PR-open — monitor `validate-stack` to
  green, then apply + validate on the live stack.
- **Playwright regression tests (mandatory for bugs):** for every bug fix, evaluate a
  regression test/assertion under `onboarding/tests/`. Applies to auth (expired
  sessions, cookie security, login redirects), routing (SSL redirect loops, broken UI
  links), UI-consumed API failures (401/500 on token refresh or console routes), form
  validation, and E2E flows. **Doesn't apply** to internal infra/logic not observable
  in the web flow (SQL query tuning, OS config, DB logic covered by unit tests, on-
  demand CLI scripts) — if you skip it, justify why in the PR. Capture network failures
  with Playwright response interceptors; add comments explaining which bug the assertion
  prevents; run `npm run test:all` in `onboarding` and confirm the new assertion passes.

## Runbook: Instagram `external_error 100 — "não é a dona do tópico"` (subcode 2534037)
Recurring self-healing cluster (issue **#64**, aggregates #67/#69/#72/#84/#97–#106).
Outgoing messages on `Channel::Instagram` inboxes fail with
`100 - A ação é inválida porque não é a dona do tópico` (subcode `2534037`).
- **Not our stack's bug.** Sending is 100% upstream in Chatwoot: `message.send_reply` →
  `SendReplyJob` → `Instagram::SendOnInstagramService` → `POST
  graph.instagram.com/v22.0/<ig_id>/messages`. Our `middleware/` is not in the failure
  path; our IaC only supplies the app creds. `performed_by: nil` in the broadcast is a
  symptom (status of an already-`failed` message), not the cause.
- **Diagnosed empirically (#64):** `GET /me` confirms the channel owner, `GET
  /<ig_id>/conversations` shows the account owns the thread, participants match the
  `recipient.id` Chatwoot uses — addressing/ownership/token/24h-window all correct, yet
  the send POST is rejected while the profile GET works. Read OK + send blocked =
  **permission/mode gating of the Meta App**, not data.
- **Root cause:** the Meta App lacks **Advanced Access** for
  `instagram_business_manage_messages` (or is in Development mode).
- **Fix (Meta App Dashboard — not versionable here):** App Review → Advanced Access for
  `instagram_business_manage_messages`; move the app to **Live**; reconnect the channel
  (re-OAuth) so the token carries the scopes; validate by resending and checking
  `messages.status = sent` + no `external_error 100` in `nexaduo-chatwoot-sidekiq-1`.
- **Playwright N/A:** the failure is in an async Sidekiq job; the UI POST returns 200 and
  only later flips to `failed` — not observable as an HTTP error in the web flow, and
  there's no controllable Instagram connection in CI. Verify via API/DB/logs.

## Lessons: DB migrations in existing environments
- `01-init.sql` runs only on first Postgres init (empty volume), so existing
  environments never received tables/columns added to it later — which broke the admin
  `users`/`sessions` seed. **Rule: to change the middleware/self_healing schema, edit
  only `01-init.sql`, keeping everything idempotent** (`CREATE ... IF NOT EXISTS`,
  `\gexec`). Reapply it against the running Postgres via `docker exec psql` so any
  environment converges to the versioned schema — no manual migration.

## Lesson: reboot recovery, inode-swap bind mounts & external uptime (issue #138)
On 2026-07-07 a WSL/host reboot took production down for **~6h**: core containers
(`nexaduo-postgres-1`, `nexaduo-chatwoot-rails-1`) came back unhealthy because
**single-file bind mounts break on inode swap** after a reboot (the host source can
even flip to an empty directory — we found `/opt/nexaduo/postgres/01-init.sql` had
become a dir), so containers exited **127** with `RestartCount=0`; `restart:
unless-stopped` could not self-heal; `cloudflared` stayed up so the tunnel still
answered and **nothing alerted**. Fixes, all in code:
- **Auto boot recovery.** `scripts/boot-recover.sh` waits for the Docker daemon then
  runs `run-stack.sh up` (never `-v`; postgres volume SACRED) and verifies
  postgres + chatwoot-rails reach `healthy` before writing `.last-boot-recover`.
  `run-stack.sh install-cron` (run by every `up`) installs it as a **@reboot user
  cron** (works because `/etc/wsl.conf` has `systemd=true`) and, best-effort with
  sudo, an **`/etc/wsl.conf [boot] command`**. `health-check-all.sh` **fails** if the
  `@reboot ... boot-recover.sh` entry is missing (documented != running).
- **Inode-swap fragility.** Prefer **directory mounts over single-file bind mounts**
  (same fix as loki/promtail/prometheus, #113/#116). Postgres init is now
  `…/infrastructure/postgres:/docker-entrypoint-initdb.d:ro`; the Chatwoot
  initializers moved to `deploy/chatwoot-initializers/`, mounted as a directory to
  `/nexaduo-initializers:ro` and copied into `config/initializers/` at container
  start (so the current file content is always read on (re)start).
- **External/independent uptime probe.** `.github/workflows/uptime-probe.yml` runs
  `scripts/uptime-probe.sh` against the public tunnel URLs every 10 min **on GitHub's
  infra** (so it alerts even when the host is down — an on-host probe can't). On
  downtime it opens/updates a GitHub issue (label `uptime-down`) and, if the Actions
  secret `UPTIME_ALERT_WEBHOOK` is set, POSTs a JSON alert to it.

## Lesson: silent infra failures & "documented ≠ running" (retro 2026-07-01)
- **Verification is active, not trust in docs.** Before assuming something works, confirm
  the live reality: `crontab -l`, `docker ps`, the newest dump's mtime, a real HTTP
  probe. "It's in AGENTS.md" is not evidence it's running.
- **Every schedule needs silent-failure detection.** A backup/job that can fail quietly
  needs a success marker + a staleness check that **fails** a health check when the
  newest artifact is too old (e.g. dump ≥26h).
- **Verify before acting.** Don't build a fix/IaC on an inferred fact (an ID's owner, a
  value's meaning). A wrong assumption once cost a whole reverted migration.
- **No premature success on async flows.** Confirm the terminal state (status/log/job
  result), not the enqueue step.
