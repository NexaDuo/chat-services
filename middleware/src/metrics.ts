import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export type Metrics = {
  registry: Registry;
  difyTokensTotal: Counter<"account_id" | "kind">;
  difyRequestsTotal: Counter<"account_id" | "status">;
  difyRequestDuration: Histogram<"account_id" | "status">;
  errorsTotal: Counter<"account_id" | "reason">;
  handoffsTotal: Counter<"account_id">;
  /** Groups skipped because DIFY_KILL_SWITCH was ON at flush time (issue #184). */
  difyKillSwitchSkipsTotal: Counter<"account_id">;
  /**
   * Incoming `message_created` webhooks whose `content` was empty, per
   * account and content type — split by whether we answered with a derived
   * marker or genuinely skipped (issue #203). Without this, the silence
   * this issue fixes could regress invisibly, same lesson as the
   * silent-failure-detection rule in AGENTS.md.
   */
  emptyContentTotal: Counter<"account_id" | "type" | "outcome">;
  /**
   * Incoming `message_created` webhooks where a content-marker signal (story
   * reply/mention, attachment) was detected ALONGSIDE non-empty `content`
   * (issue #208) — e.g. an Instagram story reply that also carries an emoji.
   * Deliberately a SEPARATE counter from `emptyContentTotal` rather than a
   * new value of its `outcome` label: `emptyContentTotal`'s name and existing
   * dashboards/alerts are specifically about the empty-content case (issue
   * #203); silently changing what "answered_with_marker" means there, or
   * counting a non-empty-content webhook under a metric named
   * `..._empty_content_...`, would be exactly the "reused metric name whose
   * meaning changes" the issue calls out to avoid. Without this counter, a
   * regression that stopped deriving the marker for non-empty content (the
   * bug this issue fixes) would again be invisible.
   */
  contentMarkerWithTextTotal: Counter<"account_id" | "type">;
};

export function createMetrics(): Metrics {
  const registry = new Registry();
  registry.setDefaultLabels({ service: "nexaduo-middleware" });
  collectDefaultMetrics({ register: registry });

  const difyTokensTotal = new Counter({
    name: "middleware_dify_tokens_total",
    help: "Total Dify tokens consumed, per account and kind (prompt/completion).",
    labelNames: ["account_id", "kind"] as const,
    registers: [registry],
  });

  const difyRequestsTotal = new Counter({
    name: "middleware_dify_requests_total",
    help: "Total Dify chat-messages requests, per account and status (ok/error).",
    labelNames: ["account_id", "status"] as const,
    registers: [registry],
  });

  const difyRequestDuration = new Histogram({
    name: "middleware_dify_request_duration_seconds",
    help: "Duration (s) of Dify chat-messages requests.",
    labelNames: ["account_id", "status"] as const,
    buckets: [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30],
    registers: [registry],
  });

  const errorsTotal = new Counter({
    name: "middleware_errors_total",
    help: "Total errors in the middleware pipeline, per account and reason.",
    labelNames: ["account_id", "reason"] as const,
    registers: [registry],
  });

  const handoffsTotal = new Counter({
    name: "middleware_handoffs_total",
    help: "Total human handoffs triggered via /tools/handoff, per account.",
    labelNames: ["account_id"] as const,
    registers: [registry],
  });

  const difyKillSwitchSkipsTotal = new Counter({
    name: "middleware_dify_kill_switch_skips_total",
    help: "Groups skipped at flush time because DIFY_KILL_SWITCH was ON, per account (issue #184).",
    labelNames: ["account_id"] as const,
    registers: [registry],
  });

  const emptyContentTotal = new Counter({
    name: "middleware_empty_content_total",
    help: "Incoming messages with empty content, per account/type/outcome (answered_with_marker vs skipped) — issue #203.",
    labelNames: ["account_id", "type", "outcome"] as const,
    registers: [registry],
  });

  const contentMarkerWithTextTotal = new Counter({
    name: "middleware_content_marker_with_text_total",
    help: "Incoming messages where a content-marker signal (story reply/mention, attachment) was detected alongside non-empty content, per account/type — issue #208.",
    labelNames: ["account_id", "type"] as const,
    registers: [registry],
  });

  return {
    registry,
    difyTokensTotal,
    difyRequestsTotal,
    difyRequestDuration,
    errorsTotal,
    handoffsTotal,
    difyKillSwitchSkipsTotal,
    emptyContentTotal,
    contentMarkerWithTextTotal,
  };
}
