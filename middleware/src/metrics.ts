import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

export type Metrics = {
  registry: Registry;
  difyTokensTotal: Counter<"account_id" | "kind">;
  difyRequestsTotal: Counter<"account_id" | "status">;
  difyRequestDuration: Histogram<"account_id" | "status">;
  errorsTotal: Counter<"account_id" | "reason">;
  handoffsTotal: Counter<"account_id">;
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

  return {
    registry,
    difyTokensTotal,
    difyRequestsTotal,
    difyRequestDuration,
    errorsTotal,
    handoffsTotal,
  };
}
