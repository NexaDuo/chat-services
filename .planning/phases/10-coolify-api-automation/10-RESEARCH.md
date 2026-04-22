# Phase 10: Coolify API Automation — Research

**Researched:** 2026-04-21
**Domain:** Infrastructure-as-Code (Terraform), Coolify v4 API, Service Orchestration
**Confidence:** MEDIUM–HIGH (provider is community-maintained and explicitly marked *"still in development"* by upstream)
**Provider under analysis:** `SierraJC/coolify` v0.10.2 (as pinned in `infrastructure/terraform/envs/production/tenant/providers.tf:8-9`)

## Summary

Phase 10 must move the tenant layer from "one `coolify_service` per stack wrapping a monolithic compose file" toward the most declarative model the `SierraJC/coolify` provider actually supports today, without regressing the v1.0 working path.

After auditing the provider registry and the current tenant layer (`infrastructure/terraform/envs/production/tenant/main.tf:15-152`), the reality is:

- **`coolify_service` is the only production-grade resource for multi-container stacks.** It takes a single `compose` raw string and does *not* expose health checks, deployment settings, restart policies, or granular per-container resources. Splitting our four stacks into finer-grained Terraform resources is **not feasible** in the current provider.
- **`coolify_service_envs` is available and unused.** Today we inject every secret via `templatefile()` into the compose string (main.tf:23-29, 52-58, 85-97, 124-136). Migrating secret injection out of the compose body and into a dedicated `coolify_service_envs` resource is the single highest-leverage declarative improvement available.
- **True "100% declarative" is blocked at the provider boundary** for three concerns: `destination` creation, `project_environment` creation, and health-check / deployment-setting configuration. Each needs either a manual Coolify UI step or a bootstrap-script fallback. These must be explicitly scoped as *accepted gaps* in Phase 10, not pretended away.

**Primary recommendation:** Adopt a **layered declaration pattern**: keep `coolify_service` + `compose` for *topology and wiring* (networks, volumes, image refs, depends_on between containers), and move all runtime secrets / per-tenant config to `coolify_service_envs` blocks driven by for_each over GCP Secret Manager versions. Leave deployment settings (autodeploy, branch, watch paths) and health-check policies expressed inside the compose `healthcheck:` stanzas until the upstream provider catches up.

<user_constraints>
## User Constraints (from prompt + MILESTONES v1.1)

### Locked Decisions
- [D-10-01]: Target is **100% declarative Terraform-driven service provisioning** for Chatwoot, Dify, NexaDuo stacks (MILESTONES.md v1.1 Key Goals).
- [D-10-02]: Provider is pinned to `SierraJC/coolify` v0.10.2 — do not change provider source in this phase.
- [D-10-03]: Must not regress the 3-step deployment (Foundation → Bootstrap → Applications) established in Phase 09.
- [D-10-04]: Secrets stay in GCP Secret Manager (D-06-01); no plaintext in Terraform state.

### Agent Discretion
- Whether to keep monolithic compose per stack or split into `coolify_service` per logical tier.
- Strategy for handling provider gaps (scripted fallback vs. manual UI vs. deferred to v1.2).
- Conventions for `for_each` secret-to-env mapping.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-06 | Automate Coolify v4 application and service configuration via Terraform/API — v1.1 milestone: 100% declarative (no manual UI steps). | Partially achievable — see "Accepted Gaps". |
| INFRA-06.a | Environment variable management fully declarative and secret-rotation-safe. | `coolify_service_envs` schema verified — multi-env block pattern supported. |
| INFRA-06.b | Project / environment orchestration declarative. | `coolify_project` ✅ supported; `project_environment` ❌ not a resource — `environment_name` string is the only lever. |
| INFRA-06.c | Health checks and deployment settings configurable via API. | ❌ Not exposed by `coolify_service` schema — must remain in compose. |
| INFRA-06.d | Complex compose handling (multiline strings vs external files) clarified. | `compose` attribute is a raw string — `templatefile()` remains the correct pattern. |
| INFRA-06.e | Dependency management between services expressed in Terraform. | Standard `depends_on` works between `coolify_service` resources; **no intra-compose per-container dependency via provider.** |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Service topology (containers, networks, volumes) | Compose file (`deploy/*.yml`) | Terraform templatefile | Provider does not model per-container resources. |
| Service wiring (project, server, env name) | Terraform `coolify_service` | — | Native provider resource. |
| Environment variables / secrets | Terraform `coolify_service_envs` | GCP Secret Manager | Proposed migration — removes secrets from compose body. |
| Stack-to-stack dependency | Terraform `depends_on` | — | Works today (main.tf:60-62, 99-101, 138-142). |
| Health checks | Compose `healthcheck:` | — | Provider has no schema for it. |
| Deploy triggers (rolling, watch paths, branch) | Compose + Coolify UI | — | Out of provider scope — UI bootstrap one-time. |
| Destinations | Coolify UI / bootstrap script | — | No `coolify_destination` resource exists; UUID fetched from Secret Manager today. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `SierraJC/coolify` | 0.10.2 | Coolify API provider | Already pinned; only viable community provider for Coolify v4. |
| Terraform | 1.5+ | IaC engine | Phase 06/09 standard. |
| `hashicorp/google` | ~> 5.0 | GCP Secret Manager access | Source of truth for secrets (D-06-01). |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| `templatefile()` builtin | N/A | Inject values into compose YAML | Keep for non-secret topology knobs (URLs, image tags). |
| Coolify REST API (direct `curl`) | v4 | Bootstrap-only fallback (destination creation, health-check polling) | If a setting has no resource; invoked from `scripts/bootstrap-coolify.sh`. |

## Architecture Patterns

### Recommended layout (target state for Phase 10)
```
infrastructure/terraform/envs/production/tenant/
├── providers.tf          # unchanged — coolify 0.10.2 pinned
├── main.tf               # coolify_project + 4x coolify_service (compose-only, no envs inline)
├── envs.tf               # NEW — 4x coolify_service_envs driven by for_each over Secret Manager
├── secrets.tf            # unchanged — google_secret_manager_secret_version data sources
└── variables.tf          # unchanged
deploy/
├── docker-compose.shared.yml    # strip ${POSTGRES_PASSWORD}, keep ${TUNNEL_TOKEN} topology
├── docker-compose.chatwoot.yml  # likewise
├── docker-compose.dify.yml      # likewise
└── docker-compose.nexaduo.yml   # likewise
```

### Pattern 1 — Compose-only topology in Terraform
**What:** `coolify_service.compose` contains only the structural parts of the stack (services, volumes, networks, image refs, healthchecks, depends_on inside compose). All `${SECRET}` interpolations are removed from the compose body.
**Why:** Compose becomes a pure topology document; secret rotation no longer triggers a `templatefile()` diff.
**Example:**
```hcl
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = "production"
  instant_deploy   = true
  compose          = file("${path.root}/../../../../../deploy/docker-compose.shared.yml")

  lifecycle {
    ignore_changes = [server_uuid, project_uuid, destination_uuid, environment_name]
  }
}
```

### Pattern 2 — `coolify_service_envs` for runtime secrets
**What:** One `coolify_service_envs` per `coolify_service`, with `env` blocks built from a map of GCP Secret Manager data sources.
**Example:**
```hcl
locals {
  shared_envs = {
    POSTGRES_USER     = var.postgres_user
    POSTGRES_PASSWORD = data.google_secret_manager_secret_version.postgres_password.secret_data
    REDIS_PASSWORD    = data.google_secret_manager_secret_version.redis_password.secret_data
    TUNNEL_TOKEN      = data.google_secret_manager_secret_version.tunnel_token.secret_data
  }
}

resource "coolify_service_envs" "shared" {
  uuid = coolify_service.shared.uuid

  dynamic "env" {
    for_each = local.shared_envs
    content {
      key        = env.key
      value      = env.value
      is_literal = true
    }
  }
}
```
**Verified attributes** for the `env` block (from `docs/resources/service_envs.md`): `key`, `value`, `is_build_time`, `is_literal`, `is_multiline`, `is_shown_once`. `is_preview` is deprecated for services.

### Pattern 3 — Stack-level `depends_on` (unchanged)
`depends_on = [coolify_service.shared]` at the resource level still drives ordering between stacks. This already works (main.tf:60-62, 99-101, 138-142) and requires no change.

### Pattern 4 — Health checks in compose
Keep `healthcheck:` stanzas inside `deploy/*.yml`. Terraform cannot configure them today; moving them inline in compose is the declarative answer that survives Coolify UI drift because Coolify honours compose-level healthchecks.

### Anti-patterns to avoid
- **Inlining secrets into `compose` via `templatefile()`** when `coolify_service_envs` can carry them. Current main.tf:23-29, 52-58, 85-97, 124-136 is the pattern to retire.
- **Trying to model `coolify_destination` or `coolify_project_environment`** as resources. They do not exist in v0.10.2; bootstrap-script-and-Secret-Manager is the only path.
- **Using `docker_compose` / `docker_compose_raw` / `health_check_*` attributes** on `coolify_service`. These are **not in the provider schema** — using them will throw "unsupported argument" errors.
- **Splitting a stack into one `coolify_service` per container.** The `coolify_service` resource represents an entire Coolify "Service" (= one compose project), not a container. Finer granularity is not achievable within the current provider.
- **Deleting `force_redeploy_hash`/`FORCE_REDEPLOY_HASH`** wholesale: it is still the only lever to force a redeploy when a secret *inside* the compose body rotates. After migrating to `coolify_service_envs` the hash becomes redundant only for the secrets that actually moved out.

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| `coolify_service` resources | 4 (`shared`, `chatwoot`, `dify`, `nexaduo`) — main.tf:15, 44, 77, 116 | Keep; drop secret interpolation from `templatefile()` call. |
| Secret interpolations inside compose via `templatefile()` | ~14 (POSTGRES, REDIS, TUNNEL, CHATWOOT, DIFY, EVOLUTION, HANDOFF, GRAFANA) | Migrate to `coolify_service_envs`. |
| Non-secret `templatefile()` variables (URLs, image tags, usernames, TZ) | ~8 (CHATWOOT_FRONTEND_URL, DIFY_*_URL, MIDDLEWARE_IMAGE, SELF_HEALING_IMAGE, TZ, POSTGRES_USER, GRAFANA_ADMIN_USER, CHATWOOT_WEBHOOK_TOKEN="dummy-token") | Leave in `templatefile()` — they are structural config, not secrets. |
| `depends_on` edges | 3 (chatwoot→shared, dify→shared, nexaduo→shared+chatwoot+dify) | Keep as-is. |
| `lifecycle.ignore_changes` | On all 4 services for server/project/destination/environment | Keep as-is — compensates for Coolify UI drift on immutable fields. |
| `FORCE_REDEPLOY_HASH` in shared stack | main.tf:24 | Review after envs migration; likely still needed for topology-only changes. |

## Accepted Gaps (require non-Terraform fallback)

These gaps are **blocking for "100% declarative"** and must be explicitly owned as out-of-provider concerns:

| Gap | Current workaround | Future Phase trigger |
|-----|--------------------|----------------------|
| No `coolify_destination` resource | Destination created manually once; UUID stored in `coolify_destination_uuid` secret (main.tf:19,48,81,120); read via `data.google_secret_manager_secret_version`. | Reopen when provider adds `coolify_destination`. |
| No `coolify_project_environment` resource | Use string `environment_name = "production"`. Works, but we cannot create additional environments declaratively. | Single-env deployment is acceptable for v1.x tenants. |
| No health-check attributes on `coolify_service` | Express `healthcheck:` inside compose YAML. | Upstream issue — track provider changelog. |
| No deployment-setting attributes (autodeploy, branch, watch paths) | Configure once via Coolify UI; `ignore_changes` prevents drift overwrite. | Track upstream; likely ties to `coolify_application` graduating from "Partial". |
| No granular `coolify_application` per container | Entire stack is one `coolify_service` + compose. | Upstream matrix lists Applications as "Partial" — revisit in v1.2. |
| No Coolify-native secret rotation trigger | `force_redeploy_hash` + `coolify_service_envs` lifecycle; a change to an env triggers reconcile on next apply. | Would need an explicit `redeploy` resource — not on provider roadmap as of v0.10.2. |

## Common Pitfalls

### Pitfall 1 — `coolify_service.compose` drift from Coolify UI
**What goes wrong:** Someone edits the compose in the Coolify UI; next `terraform apply` overwrites it.
**How to avoid:** Keep compose as the Terraform source of truth. Consider adding `compose` to `ignore_changes` only if the team deliberately hand-edits compose in UI — we do not, so **do not** add it.

### Pitfall 2 — Secret value in Terraform state
**What goes wrong:** Moving secrets into `coolify_service_envs.env.value` means the plaintext value lands in `terraform.tfstate`.
**How to avoid:** This is the same risk surface as the current `templatefile()` approach — state is already sensitive. Mitigation is unchanged: GCS state bucket encryption + IAM restriction (Phase 06 decision D-06-02). Document clearly in the phase PLAN.

### Pitfall 3 — `coolify_service_envs` UUID coupling
**What goes wrong:** `uuid = coolify_service.shared.uuid` forces `coolify_service_envs` to wait on service creation — but if the service is *replaced*, the envs resource can lose its binding.
**How to avoid:** Rely on Terraform's implicit graph (the reference) rather than `depends_on`. If replacement happens, both resources will be recreated together.

### Pitfall 4 — Multiline secret values
**What goes wrong:** Some secrets (e.g., private keys, JSON credentials) contain newlines; Coolify's env-var UI truncates or escapes incorrectly.
**How to avoid:** Set `is_multiline = true` on the `env` block. Schema supports this per `docs/resources/service_envs.md`.

### Pitfall 5 — Re-ordering `env` blocks triggers no-op diffs
**What goes wrong:** `for_each` over an unordered `map` produces stable ordering; a naive `list(object)` reorders on every apply.
**How to avoid:** Always drive `coolify_service_envs` from a **map** (`for_each`), not a list. Terraform will key by env-var name, producing stable diffs.

### Pitfall 6 — `instant_deploy = true` and env-var race
**What goes wrong:** `coolify_service` with `instant_deploy = true` may trigger a deploy *before* `coolify_service_envs` has populated the envs, causing containers to crash-loop.
**How to avoid:** Two options to evaluate in PLAN:
  - (a) set `instant_deploy = false` on `coolify_service`, let `coolify_service_envs` populate, then `terraform apply -replace` or a small post-apply `null_resource` triggers the deploy via API.
  - (b) keep `instant_deploy = true` and accept one cold-start failure on initial create — idempotent reconcile recovers on the next loop.
  Recommend (a) for production, (b) acceptable for first bring-up.

## Implementation Phasing (feeds into 10-XX-PLAN.md)

Suggested plan decomposition:

1. **10-01 — Env extraction**: Introduce `envs.tf` with 4x `coolify_service_envs`; migrate one stack at a time (shared → chatwoot → dify → nexaduo) to prove pattern before fan-out. Remove corresponding `${…}` interpolations from the compose file and `templatefile()` call.
2. **10-02 — Bootstrap gap coverage**: Extend `scripts/bootstrap-coolify.sh` to idempotently ensure a default destination exists and to write `coolify_destination_uuid` to Secret Manager if missing (it currently assumes manual pre-creation).
3. **10-03 — Deploy-trigger reconciliation**: Add a small Terraform-driven redeploy hook (null_resource + `coolify` REST `POST /deploy`) for cases where only an env changed — avoids relying on `FORCE_REDEPLOY_HASH`.
4. **10-04 — Documentation & drift check**: Update `ARCHITECTURE.md` + `infrastructure/terraform/README.md` with the envs pattern and the "accepted gaps" list.

## Sources

### Primary (HIGH confidence — verified this session)
- `infrastructure/terraform/envs/production/tenant/main.tf:1-173` — current `coolify_service` wiring.
- `infrastructure/terraform/envs/production/tenant/providers.tf:1-26` — provider pinning.
- `.planning/REQUIREMENTS.md` — INFRA-06 definition (v1.0 vs v1.1 split).
- `.planning/MILESTONES.md` v1.1 — Key Goals block.
- SierraJC/coolify provider `README` support matrix — upstream-declared "Partial / ❌" status for Destinations, Project Environments, Applications, Databases.
- SierraJC/coolify `docs/resources/service.md` — schema for `coolify_service` (required: `compose`, `environment_name`, `project_uuid`, `server_uuid`; no health-check / docker_compose_raw / redirect / connect_to_docker_network attributes).
- SierraJC/coolify `docs/resources/service_envs.md` — schema for `coolify_service_envs` (`env` block with `key`, `value`, `is_build_time`, `is_literal`, `is_multiline`, `is_shown_once`).

### Secondary (MEDIUM confidence — consulted but not exhaustively verified)
- `SierraJC/terraform-provider-coolify` repo README (community-maintained; upstream notes provider "limited by the Coolify API, which is still in development").
- Phase 09 artifacts (`09-CONTEXT.md`, `09-03-PLAN.md`) for 3-step deployment constraints.

### Gaps in sources
- `coolify_application` resource doc page (`docs/resources/application.md`) returned 404 — provider's "Partial" Applications support is not publicly documented at resource level in v0.10.2. **Do not plan against `coolify_application` in this phase.**
