/**
 * OpenTelemetry bootstrap for the middleware (ESM).
 *
 * Loaded as a preload via `node --import ./dist/telemetry.js dist/index.js`
 * so the SDK and its instrumentations are registered before any app module
 * (Fastify, pg, pino) is imported.
 *
 * Hard requirement (telemetry-contract.md): tracing must NEVER crash the app.
 * If OTEL_SDK_DISABLED=true, or the collector is unreachable, or the SDK fails
 * to start, we log a warning and continue without tracing.
 */
import { NodeSDK } from "@opentelemetry/sdk-node";
import { OTLPTraceExporter } from "@opentelemetry/exporter-trace-otlp-http";
import { resourceFromAttributes } from "@opentelemetry/resources";
import { ATTR_SERVICE_NAME } from "@opentelemetry/semantic-conventions";
import {
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
} from "@opentelemetry/sdk-trace-base";
import { HttpInstrumentation } from "@opentelemetry/instrumentation-http";
import { FastifyInstrumentation } from "@opentelemetry/instrumentation-fastify";
import { PgInstrumentation } from "@opentelemetry/instrumentation-pg";
import { PinoInstrumentation } from "@opentelemetry/instrumentation-pino";
import { diag, DiagConsoleLogger, DiagLogLevel } from "@opentelemetry/api";

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME || "middleware";

function startTelemetry(): void {
  if (
    process.env.OTEL_SDK_DISABLED === "true" ||
    process.env.OTEL_SDK_DISABLED === "1"
  ) {
    // eslint-disable-next-line no-console
    console.error(`[telemetry] OTEL_SDK_DISABLED set — tracing off (${SERVICE_NAME})`);
    return;
  }

  // Surface SDK/exporter errors as diagnostics, never as thrown exceptions.
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

  // We only wire a traceExporter below; NodeSDK would otherwise auto-create a
  // default metrics PeriodicExportingMetricReader that reads
  // OTEL_EXPORTER_OTLP_ENDPOINT straight from process.env (not the local
  // `endpoint` const below) and falls back to localhost:4318, spamming
  // ECONNREFUSED. We export no custom metrics today, so disable it outright.
  if (process.env.OTEL_METRICS_EXPORTER === undefined) {
    process.env.OTEL_METRICS_EXPORTER = "none";
  }

  const endpoint =
    process.env.OTEL_EXPORTER_OTLP_ENDPOINT || "http://otel-collector:4318";

  // Default ratio: 1.0 in dev, otherwise honor OTEL_TRACES_SAMPLER_ARG.
  const ratioArg = process.env.OTEL_TRACES_SAMPLER_ARG;
  const ratio =
    ratioArg !== undefined && ratioArg !== ""
      ? Number(ratioArg)
      : process.env.NODE_ENV === "production"
        ? 0.2
        : 1.0;
  const safeRatio = Number.isFinite(ratio) ? Math.min(Math.max(ratio, 0), 1) : 1.0;

  const sdk = new NodeSDK({
    resource: resourceFromAttributes({ [ATTR_SERVICE_NAME]: SERVICE_NAME }),
    sampler: new ParentBasedSampler({
      root: new TraceIdRatioBasedSampler(safeRatio),
    }),
    traceExporter: new OTLPTraceExporter({
      // Exporter appends /v1/traces to the base endpoint.
      url: `${endpoint.replace(/\/+$/, "")}/v1/traces`,
    }),
    instrumentations: [
      new HttpInstrumentation(),
      new FastifyInstrumentation(),
      new PgInstrumentation(),
      // Injects trace context into pino logs; we also set an explicit mixin in
      // logger.ts to guarantee the exact `trace_id` / `span_id` keys.
      new PinoInstrumentation(),
    ],
  });

  try {
    sdk.start();
    // eslint-disable-next-line no-console
    console.error(
      `[telemetry] OTel started service=${SERVICE_NAME} endpoint=${endpoint} ratio=${safeRatio}`,
    );
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[telemetry] failed to start OTel SDK; continuing without tracing", err);
    return;
  }

  const shutdown = (signal: string): void => {
    sdk
      .shutdown()
      .catch((err) => {
        // eslint-disable-next-line no-console
        console.error("[telemetry] error during OTel shutdown", err);
      })
      .finally(() => {
        process.removeListener(signal, handlers[signal]!);
        process.kill(process.pid, signal);
      });
  };
  const handlers: Record<string, NodeJS.SignalsListener> = {
    SIGTERM: () => shutdown("SIGTERM"),
    SIGINT: () => shutdown("SIGINT"),
  };
  process.once("SIGTERM", handlers.SIGTERM!);
  process.once("SIGINT", handlers.SIGINT!);
}

startTelemetry();
