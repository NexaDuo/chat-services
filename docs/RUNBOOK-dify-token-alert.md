# Runbook: Dify token-usage alert (issue #182)

## What exists

Two Grafana alert rules, provisioned as code in
[`observability/grafana/provisioning/alerting/dify-token-usage.yml`](../observability/grafana/provisioning/alerting/dify-token-usage.yml),
built on the existing `middleware_dify_tokens_total{account_id, kind}` Prometheus
counter (emitted by `middleware/src/metrics.ts`, scraped by `observability/prometheus/prometheus.yml`):

- **`dify-tokens-aggregate-spike`** — fires when `sum(increase(middleware_dify_tokens_total[15m]))`
  stays above **30000** for 5 minutes. Answers "is the whole stack burning tokens
  faster than normal" — the expected shape of a successful traffic spike (e.g. the
  LinkedIn post) but indistinguishable, by this alert alone, from a runaway/abuse
  scenario.
- **`dify-tokens-per-account-spike`** — fires when `sum by (account_id)
  (increase(middleware_dify_tokens_total[15m]))` stays above **15000** for 5 minutes,
  for any single `account_id`. Answers "is one tenant/sender anomalous" — this can
  fire even while the aggregate rule stays quiet, and is the one that would catch a
  single misbehaving sender once there's more than one tenant on the stack.

Both are evaluated every 1 minute and live in the `NexaDuo` Grafana folder (same as
the dashboards).

## Threshold justification (measured, not guessed)

Measured live against production Prometheus on 2026-08-20, before the LinkedIn post:
only `account_id=3` had traffic — 6 requests over 6h, ~10,237 tokens increase over
6h (~1,700 tokens/hour average, ~1,700 tokens/request), with the busiest observed 1h
window at ~3,335 tokens. Thresholds were set well above this baseline (~35x the
busiest observed hourly rate for the aggregate rule, ~18x for the per-account rule)
so they don't fire on ordinary low-volume/test traffic, while still firing within
minutes of a real spike rather than waiting for the invoice. See the comment block
at the top of the YAML file for the full derivation and the raw values.

To change the threshold or window: edit the YAML (the `params` under each
`threshold` expression, and the `expr`'s `[15m]` range), then re-apply:
`docker compose up -d --no-deps grafana` (recreate **only** grafana — never drag in
postgres). This is the entire "configurable in code" surface; there is no runtime
knob, deliberately, so nobody can change the threshold from the UI and lose it on
the next bootstrap.

## What it does NOT do

**Alert only. No automatic cutoff, no rate limit, no kill switch.** This was an
explicit decision on issue #182: the trade-off accepted is zero risk of dropping
legitimate traffic during a traffic spike, in exchange for zero automatic
protection — the response is human. Do not add throttling/blocking behind this
alert without a separate, explicitly-scoped decision (a future "silent discard, no
canned message" cutoff is noted as a *possible* follow-up in issue #182 but is
explicitly out of scope here).

## Expected human action when this fires

1. Open the Grafana **NexaDuo → Alerting** view (or the token-usage dashboard) and
   confirm which rule fired — aggregate, per-account, or both — and which
   `account_id` if per-account.
2. Cross-check against what's expected: is this the anticipated LinkedIn-post spike
   (aggregate fires, spread across the account(s) actually running the campaign) or
   does it look like a single account/sender driving it disproportionately (only
   per-account fires, or one `account_id` dominates the aggregate)?
3. If it's the expected spike: no action required beyond awareness — the alert is
   working as intended, it's just also the signature of `success`. Keep watching
   Azure OpenAI cost if it's available.
4. If it looks anomalous (one account/sender well beyond what a real conversation
   volume would produce, e.g. a loop, a scraper, or a misconfigured client):
   - Inspect Chatwoot for that `account_id`'s conversation volume/pattern to confirm
     it's not a legitimate burst.
   - There is no automatic mitigation — a human decides whether to pause/investigate
     that tenant manually (e.g. via Chatwoot inbox controls), understanding that
     doing so is itself a manual action outside this alert's scope, not something
     this alert performs.
5. The alert self-recovers (`inactive`/`Normal`) once the 15-minute window's
   consumption drops back under the threshold — no manual "resolve" action is
   needed for the alert state itself.

## Silent-failure detection for the alert itself

An alert rule that silently stops being evaluated (e.g. Grafana provisioning
picking up a broken file, or the rule erroring against Prometheus) is worse than no
alert — it produces false confidence. Verify liveness any time, without needing
SMTP/Grafana UI access:

```
docker exec chat-services-grafana-1 sh -c \
  'AUTH=$(printf "admin:%s" "$GF_SECURITY_ADMIN_PASSWORD" | base64); \
   wget -qO- --header="Authorization: Basic $AUTH" \
   http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules'
```

Check, for both `dify-tokens-aggregate-spike` and `dify-tokens-per-account-spike`:
`health` must be `"ok"` (not `"error"`), and `lastEvaluation` must be recent
(within the last couple of minutes, given the 1m evaluation interval). A stale
`lastEvaluation` or `health: error` means the rule stopped evaluating — treat it
like any other broken health check.

## Known gap: no working notification channel

**Pending decision, not invented here.** As of this writing, nothing in this
stack's provisioning configures an SMTP server, Slack webhook, or any other
outbound notifier — grepped every `docker-compose*.yml` and
`.env.production.example`. The rules above route to Grafana's built-in default
contact point (`grafana-default-email`), which has no SMTP backing configured and
will **not** deliver anywhere. Today, "seeing" this alert means opening Grafana
(`grafana.nexaduo.com` → Alerting) or running the liveness check above — not a
push notification outside Grafana as issue #182 asked for.

**This needs a decision from the user**: pick a real channel (email via SMTP,
Slack webhook, Telegram, etc.) and it can be wired as a Grafana contact point +
notification policy, both provisionable in this same `alerting/` directory. Until
that decision is made, this alert is silent outside of an active Grafana check.
