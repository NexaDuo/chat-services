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
   labels — verified live via the internal-only Traefik API (`--api=true`,
   `--api.insecure=false`; the actual router is gated to `127.0.0.1` only via
   an `ipAllowList` middleware in `deploy/traefik/dynamic.yml`, since 21
   containers share `nexaduo-network` and an unauthenticated API would leak
   routing topology to less-trusted ones like `dify-sandbox` — issue #151
   `@sec`). Verify with `docker exec coolify-proxy wget -qO-
   http://127.0.0.1:8080/api/http/routers` (must run *inside* the container;
   not reachable from other containers on the network). `scripts/health-check-all.sh`
   asserts this automatically (docker-provider routers present and `enabled`).
   `deploy/traefik/dynamic.yml` is a file-provider **fallback that runs
   alongside it at all times**, not a
   workaround for a known-bad provider — issue #151 found the Docker provider
   permanently down for weeks (a Docker API version-negotiation bug in
   `traefik:v3.4.5` against Docker Engine 29.x) with routing surviving only on
   this fallback, invisible because "documented as configured" was trusted
   instead of verified live. Image pinned to `traefik:v3.6.25` (fixed) — see
   the root-cause comment in `deploy/docker-compose.localproxy.yml`. Don't
   trust "it's routing" as proof the Docker provider works; check the API.
4. **Validate:** `scripts/run-stack.sh validate` smoke-tests the real tunnel URLs and
   runs the Playwright connectivity + tenant-resolution suites against them.
5. **Backup:** `scripts/backup-host.sh` (daily 03:00 cron via `run-stack.sh
   install-cron`).
6. **Host ports (isolated by default — #119, default since #145):**
   `scripts/run-stack.sh up` publishes **zero** host ports by default (via
   `deploy/docker-compose.isolated.yml`, `!reset []` merge — Compose 2.24.4+). Public
   traffic still flows via the tunnel → Traefik; service-to-service uses the Docker
   network by container name (never `localhost`/`host.docker.internal`). Local debug
   is via `docker exec` (e.g. `docker exec -it chat-services-postgres-1 psql -U postgres`).
   Opt out with `scripts/run-stack.sh --no-isolated up` (or `ISOLATED=0`) to publish
   host ports normally, e.g. for local debugging without the tunnel. `--isolated`/
   `ISOLATED=1` still work for back-compat (no-ops now that isolation is default).
7. **Compose project name:** `chat-services` (renamed from the legacy `nexaduo`
   default on 2026-07-08 to match the multi-tenant terminology below — see
   "Terminology"). Container names are `chat-services-<service>-1`; volumes are
   `chat-services_<volume>` (e.g. the SACRED `chat-services_postgres-data`). The
   Docker network stays fixed as `nexaduo-network` (external, not project-scoped).
   Override with `COMPOSE_PROJECT_NAME` if ever needed.

## Configuration model (hybrid)
1. **Static (.env):** infrastructure secrets (DB passwords, Redis URLs, etc.).
2. **Dynamic (Postgres + Middleware API):** app settings + API keys (e.g.
   `DIFY_SELF_HEALING_API_KEY`).

Internal agents (e.g. `self-healing`) fetch their functional config from the
**Middleware Config API** (`GET /config`), authenticated via `Bearer` using
`HANDOFF_SHARED_SECRET`. New keys go in the `middleware.configs` Postgres table.
This model is also how the operator manually kills the Dify webhook path in an
emergency (`DIFY_KILL_SWITCH`, issue #184, checked at flush time — see
[`docs/dify-kill-switch.md`](docs/dify-kill-switch.md) for the full ON/OFF/
verify procedure) without touching `.env` or restarting anything.
Every service block that talks to `GET /config` must receive `HANDOFF_SHARED_SECRET`
(issue #152 — it reached `middleware` but not `self-healing-agent` for an unknown
period, silently disabling that agent's LLM analysis). **Fail-loud by default:**
`self-healing/src/index.ts` `process.exit(1)`s if the secret is missing/empty, or if
`/config` never returns a usable `dify.selfHealingApiKey` after its retry/backoff
loop — production must never run "self-healing" silently detection-only. The
pre-#152 silent degrade (issue #22) survives only behind the explicit
`SELF_HEALING_ALLOW_NO_CONFIG=1` opt-in, set exclusively in
`deploy/docker-compose.ci.yml` (never inferred from `NODE_ENV`, never set in
production compose).

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
  - **The host `.env` is production config since #109** (secrets incl. `TUNNEL_TOKEN`,
    DB passwords, Azure OpenAI creds) and is deliberately not in git — a DB+volume
    restore alone can't reconnect or reach the tunnel without it. `backup-host.sh`
    therefore also tars it as `env-<ts>.tar.gz` (same rotation/off-host-copy/coverage-
    check treatment as the volume archives, no extra encryption — same trust level as
    the DB dumps already shipped to the same remote), and `health-check-all.sh`
    staleness-checks it the same way. Set `BACKUP_RCLONE_REMOTE` (see
    `.env.production.example` for Google Drive setup) or it stays local-only.
- **Postgres data is SACRED.** It lives in the Docker named volume
  `chat-services_postgres-data`. **Never** `docker compose down -v` or prune it;
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
5. `zcat <dump> | docker exec -i chat-services-postgres-1 psql -U postgres -d <db>`.
6. Start consumers; validate row counts + the app via the tunnel (`run-stack.sh validate`).
7. **Remember the Docker volumes** — a dump restore alone leaves `PrivkeyNotFoundError`;
   restore the archived volumes or re-run `flask reset-encrypt-key-pair` + re-enter the
   Azure OpenAI creds.
8. **On a fresh host, restore `.env` first** — extract the newest
   `env-<ts>.tar.gz` (`tar xzf env-<ts>.tar.gz -C /path/to/repo`) before anything
   else; without it there's nothing to authenticate the tunnel or reconnect the
   restored DB/volumes with.

## Live gotchas
- **`docker logs --since` can lie on a container with a huge unrotated log buffer**
  (issue #151): `coolify-proxy`'s log file grew to 136k+ lines (a 68k-line retried-
  forever error burst); `docker logs --since <window>` against it returned 0 lines
  even while `docker logs -f` streamed genuinely-current entries seconds later —
  an @sre log sweep trusted the empty `--since` result and wrongly reported the
  container clean. Root cause not fully isolated (suspected Docker Desktop
  WSL2-backend log-file indexing breaking down on very large/gapped buffers); the
  mitigation is log rotation (`logging.options.max-size`/`max-file`, now set on
  `coolify-proxy`) so the buffer can't grow large enough to trigger it again. If a
  container's `--since` output is empty, cross-check with `-f` for a few seconds
  before trusting "clean" — don't rely on `--since` alone for a sweep.
- **Cloudflare SSL loops:** behind the tunnel, disabling `FORCE_SSL` in apps is often
  necessary to prevent infinite redirect loops.
- **Container entrypoints:** images like Chatwoot need explicit entrypoints
  (`docker/entrypoints/rails.sh`) or they default to an interactive shell.
- **No hardcoded localhost in tests:** production tests must use env vars
  (`CHATWOOT_URL`, etc.) to support local + remote validation.
- **Recreate a service without dragging Postgres:** when reapplying a fix to one
  service, recreate **only** that service (`docker compose up -d --no-deps <svc>`) — do
  NOT run an ad-hoc chain that pulls in `chat-services-postgres-1`. The host is shared and the
  postgres data is SACRED; casual recreation risks concurrent work and the volume.

## Terminology
**NexaDuo is only one tenant** in this multi-tenant stack, not the stack itself. Do not
use "NexaDuo" as a generic name for the platform/dashboard. Call it "Multitenant Chat
Services" or "Omnichannel Stack".

## Release & validation (single environment)
There is **no** staging→prod GitHub Actions pipeline and no separate staging env — the
host-local stack behind the tunnel **is** production (issue #109). Every change
serializes on this live stack; **do not recreate shared containers (especially
`chat-services-postgres-1`)** and coordinate with concurrent work on the host.
- **CI merge gates (every PR, enforced by branch protection — issue #162):**
  - `stack-compose-playwright.yml` (job `validate-stack`) spins the whole stack up
    ephemerally on the runner and runs Playwright (Stage 1 connectivity + Stage 4
    tenant resolution).
  - `unit-tests.yml` (jobs `self-healing` and `middleware`, issue #155) runs each
    package's vitest suite (`npm test`) — `agents/self-healing/**` and
    `middleware/**` unit tests were previously green locally but never executed by
    any workflow, so a broken test could merge undetected. Split into two jobs
    because the packages pin different vitest majors (self-healing `^2.1.9`,
    middleware `^4.1.6`) and neither should wait on the ephemeral stack spin-up
    (nor have a stack flake mask a unit failure or vice versa).
  Monitor both to green (`gh run watch`).
  - **Platform enforcement (issue #162 — configuration and proof recorded in that
    issue's comments; verify current state with
    `gh api repos/NexaDuo/chat-services/branches/main/protection`, which is the only
    authority here since repo settings live outside git).** `main` carries branch
    protection with four **required status checks** — `validate-stack`, `secret-scan`,
    `middleware`, `self-healing`. Force pushes and branch deletion are blocked.
    `enforce_admins: true`, so the rule binds the repo owner too. There is **no**
    required-review rule (`required_pull_request_reviews: null`) — deliberate: this repo's
    PRs are authored by a single human with agent assistance, and requiring a non-author
    approval would park every PR at `REVIEW_REQUIRED` and turn `--admin` into the normal
    merge path. `strict` (require-branch-up-to-date) is **off**; re-running CI on every
    intervening merge costs more than the semantic conflicts it would catch at this
    volume.
    - **All three bypasses were observed refusing**, not assumed (the criterion this issue
      was filed on): a merge attempt with a red required check returned *"the base branch
      policy prohibits the merge"* (`mergeStateStatus=BLOCKED`); a real direct push to
      `main` was rejected with `GH006 ... protected branch hook declined`; and
      `gh pr merge --admin` was refused (see below). Each was run against a throwaway PR
      whose payload was chosen so that the *unexpected* outcome would also be recoverable —
      an empty commit rather than a broken one. That is what made the experiments runnable
      at all: with a failing test as the payload, the cost of "it merged" would have been a
      red `main`, and the claim would have gone untested again. Design the experiment so
      either result is survivable. Evidence trail: issue #162 comments; scratch PRs #168 and
      #170, both closed unmerged.
    - **`git push --dry-run` is NOT a valid oracle for this** — it reports success whether
      `enforce_admins` is on or off. A check that returns the same answer in both states
      measures nothing; use a real push or a real merge attempt. An **empty** commit is the
      right payload for a real push test — it is *recoverable*, not free: it would still
      advance `main`, appear in history, and trigger push-triggered workflows. Prefer the
      merge-attempt form when you only need to test the merge path, since a refused merge
      mutates nothing at all.
    - **`mergeable` is not the field to read** — it reports textual conflicts only and
      stays `MERGEABLE` on a policy-blocked PR. Read `mergeStateStatus`.
    - The `@sec` + `@rev` dual review gate remains **convention, not platform-enforced**;
      nothing in GitHub checks for those markers.
    - **`gh pr merge --admin` does NOT bypass this** — verified, don't reach for it in an
      incident expecting it to work: `enforce_admins: true` binds admins to the required
      checks, and the attempt fails with `GraphQL: N of N required status checks are in
      progress. (mergePullRequest)`. Where `--admin` *is* described as the override of last
      resort, that applies to a *review* requirement — which this repo deliberately does not
      have — not to required status checks under admin enforcement.
    - **The only real escape hatch is toggling `enforce_admins` off** in repo settings
      (`gh api -X DELETE repos/NexaDuo/chat-services/branches/main/protection/enforce_admins`),
      merging, then re-enabling it. That is deliberately more friction than a flag: it is
      visible in the org audit log, and it forces the decision to be explicit. Re-enable in
      the same session — an "off" that outlives the incident is how a repo ends up back at
      #162.
    - Repo settings live outside git, so this paragraph is the audit record. If the
      settings change, change it here in the same breath — the #151 lesson is that a doc
      claiming a guarantee reality doesn't back is worse than no doc.
- **Mandatory phases (single env):** CI green → apply the merged change to the live
  stack (`scripts/run-stack.sh up`, or recreate only the affected service — never
  `down -v`, never postgres unnecessarily) → validate on the real environment
  (`scripts/run-stack.sh validate` — real tunnel URLs + Playwright) → confirm health
  (`scripts/health-check-all.sh` + inspect the affected `chat-services-*` containers). If a
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
`100 - A ação é inválida porque não é a dona do tópico` (subcode `2534037`) while
**inbound keeps working** — that asymmetry is the whole tell.

- **Root cause (proven live 2026-08-19, issue #173): Conversation Routing.** The
  Instagram account has a **Facebook Page linked**, which puts the thread under Meta's
  Conversation Routing. When the Page's **default routing app** is not ours, our app is
  only a *secondary receiver*: it receives every webhook (inbound works) but has **no
  right to send** (every outbound rejected with `2534037`). For `miau.duda` the linked
  Page is "Maria Eduarda".
- **Fix (Meta, not versionable here):** Page Settings → Page setup → **Advanced
  messaging** → **Default routing app** → set to the app that owns the channel
  (`Maria Eduarda - IG`, Instagram App ID `1042111571516215`).
- **Validate:** resend through the product path and confirm the **terminal** state —
  `messages.status = sent` **and `source_id` populated** (Chatwoot only writes
  `source_id` from an accepted API response), with no Instagram error line in
  `chat-services-chatwoot-sidekiq-1`. Proof from #173, four minutes apart on the same
  DB: msg `51` `status=3` (failed), no `source_id` → msg `54` `status=0` (sent), with
  `source_id`, `Performed SendReplyJob in 762.18ms`.
- **Not our stack's bug.** Sending is 100% upstream in Chatwoot: `message.send_reply` →
  `SendReplyJob` → `Instagram::SendOnInstagramService` → `POST
  graph.instagram.com/v22.0/<ig_id>/messages`. Our `middleware/` is not in the failure
  path; our IaC only supplies the app creds. `performed_by: nil` in the broadcast is a
  symptom (status of an already-`failed` message), not the cause.

### Superseded: what this runbook used to claim, and why it cost months
This runbook previously stated the root cause was the Meta App lacking **Advanced
Access** for `instagram_business_manage_messages` (or being in Development mode). **That
is wrong**, and it is recorded here rather than deleted so nobody re-derives it. Acting
on it burned Advanced Access, Live mode, an accepted Instagram Tester, re-OAuth and the
"Allow access to messages" toggle — **none** of which were the problem (all tested live
2026-07-01 and 2026-07-07).

The false premise underneath it: *"`miau.duda` is a pure Instagram-Login connection with
no Facebook Page surface."* That was **assumed and never verified**. Because Meta
documents Conversation Routing only for Page-linked accounts, the assumption made the
team discard the exact mechanism that was causing the failure. This is the `AGENTS.md`
rule "**verify before acting** — don't build on an inferred fact" failing in the most
expensive way available.

### How to test this class of bug (three traps, all hit for real)
1. **Always open a real 24h window before concluding anything.** Meta validates the
   messaging window **before** thread ownership, so a stale thread returns
   `code=10 / subcode=2534022` ("outside allowed window") which **masks** `2534037`. A
   *different* error is not evidence of progress when the tested condition changed too.
2. **Vary the sender, not the Chatwoot conversation.** Instagram has **one thread per
   person**; Chatwoot conversations are just resolved/reopened slices of the same IG
   thread. Creating a new Chatwoot conversation does **not** create a new IG thread — to
   test a genuinely new thread you need someone who has never DMed the account.
3. **An outgoing message with `status=2` (read) can be a native echo.** Instagram echoes
   messages sent from its own inbox over the webhook, and Chatwoot records them as
   outgoing. A native echo is not proof that the API send works — check `source_id` and
   the Sidekiq log.

Isolate with a **controlled comparison**: same app, same token-acquisition path, same
`account_type`, two different accounts, same minute. In #173 that produced
`alexandrelmachado` → HTTP 200 vs `miau.duda` → `2534037`, which eliminated the app,
the OAuth token path, and `account_type` in one shot.

**Gotcha:** `GET /me/conversations` returns `paging.next` with the `access_token`
embedded in the URL — never print the raw response; filter it or extract only the
fields you need.

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
