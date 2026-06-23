import { trace, isSpanContextValid } from "@opentelemetry/api";

/**
 * Structural logger interface — compatible with both `pino.Logger` and
 * Fastify's `FastifyBaseLogger`. We keep it narrow on purpose so clients
 * can accept either without version skew between pino major versions.
 */
export interface Logger {
  trace: LogFn;
  debug: LogFn;
  info: LogFn;
  warn: LogFn;
  error: LogFn;
  fatal: LogFn;
}

interface LogFn {
  (msg: string, ...args: unknown[]): void;
  (obj: unknown, msg?: string, ...args: unknown[]): void;
}

/**
 * Produces the Fastify `logger` option value (a pino config object) from the
 * app config. Letting Fastify instantiate pino itself avoids cross-version
 * type conflicts when we'd otherwise pass `loggerInstance: myPino`.
 */
export function buildFastifyLoggerConfig(level: string): object {
  // Pretty output ONLY in interactive dev. In production (or any non-TTY
  // stdout) we emit raw NDJSON so Promtail can parse it and the trace_id
  // derived field works. See telemetry-contract.md.
  const usePretty =
    process.env.NODE_ENV !== "production" && process.stdout.isTTY;

  return {
    level,
    base: { service: "middleware" },
    timestamp: () => `,"time":"${new Date().toISOString()}"`,
    // trace_id / span_id injected from the active OTel span context.
    mixin: otelLogMixin,
    ...(usePretty
      ? {
          transport: {
            target: "pino-pretty",
            options: {
              colorize: true,
              translateTime: "HH:MM:ss.l",
              ignore: "pid,hostname,service",
              singleLine: true,
            },
          },
        }
      : {}),
  };
}

/**
 * Pino `mixin` that injects the active OpenTelemetry span context as
 * `trace_id` (32-hex) and `span_id` (16-hex) on every log line, matching the
 * keys the Grafana/Loki derived field expects. Returns an empty object when
 * there is no active span (or the OTel API is unavailable), so logging never
 * depends on tracing being up.
 */
function otelLogMixin(): Record<string, string> {
  const span = trace.getActiveSpan();
  if (!span) return {};
  const ctx = span.spanContext();
  if (!ctx || !isSpanContextValid(ctx)) return {};
  return { trace_id: ctx.traceId, span_id: ctx.spanId };
}
