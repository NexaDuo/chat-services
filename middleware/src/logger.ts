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
    // Chatwoot delivers its webhook token in the query string, so the raw
    // request URL is secret-bearing. Scrub it before it reaches stdout —
    // otherwise the token lands in Loki, in `docker logs`, and in anything
    // that ships them onward.
    serializers: { req: redactingReqSerializer },
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

/** Query params whose value must never be logged. */
const SECRET_QUERY_PARAMS = new Set(["token", "access_token", "api_key", "apikey"]);

/**
 * Fastify request serializer mirroring the default shape, but with
 * secret-bearing query parameters replaced by `<redacted>` in `url`.
 */
function redactingReqSerializer(request: {
  method?: string;
  url?: string;
  // `ip` and `host` are Fastify's getters, which honour `trustProxy` (set in
  // index.ts) and resolve the real client through X-Forwarded-For. Reading
  // `socket.remoteAddress`/`headers.host` instead would log the reverse
  // proxy on every line — the whole stack sits behind coolify-proxy, so that
  // would silently blind every request log, not just this webhook.
  ip?: string;
  host?: string;
  headers?: Record<string, unknown>;
  socket?: { remoteAddress?: string; remotePort?: number };
}): Record<string, unknown> {
  return {
    method: request.method,
    url: redactUrlSecrets(request.url),
    host: request.host ?? request.headers?.host,
    remoteAddress: request.ip ?? request.socket?.remoteAddress,
    remotePort: request.socket?.remotePort,
  };
}

/** Exported for tests — mirrors Fastify's default serializer shape. */
export const __testing = { redactingReqSerializer };

/**
 * Replaces the value of any secret-bearing query parameter with `<redacted>`,
 * leaving the path and every other parameter intact. Falls back to dropping
 * the whole query string if the URL cannot be parsed — never log what we
 * could not inspect.
 */
export function redactUrlSecrets(url: string | undefined): string | undefined {
  if (!url) return url;
  const queryStart = url.indexOf("?");
  if (queryStart === -1) return url;

  const path = url.slice(0, queryStart);
  try {
    const params = new URLSearchParams(url.slice(queryStart + 1));
    let touched = false;
    for (const key of [...params.keys()]) {
      if (SECRET_QUERY_PARAMS.has(key.toLowerCase())) {
        params.set(key, "<redacted>");
        touched = true;
      }
    }
    if (!touched) return url;
    return `${path}?${params.toString()}`;
  } catch {
    return `${path}?<unparseable-query-redacted>`;
  }
}
