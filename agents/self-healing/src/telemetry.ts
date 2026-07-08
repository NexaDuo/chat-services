/**
 * OpenTelemetry bootstrap for the self-healing agent (CommonJS).
 *
 * Loaded as a preload via `node --require ./dist/telemetry.js dist/index.js`
 * so the SDK and its instrumentations are registered before any app module
 * (pg, pino, http) is imported.
 *
 * Hard requirement (telemetry-contract.md): tracing must NEVER crash the app.
 * If OTEL_SDK_DISABLED=true, or the collector is unreachable, or the SDK fails
 * to start, we log a warning and continue without tracing.
 */
import { NodeSDK } from '@opentelemetry/sdk-node';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { ATTR_SERVICE_NAME } from '@opentelemetry/semantic-conventions';
import {
  ParentBasedSampler,
  TraceIdRatioBasedSampler,
} from '@opentelemetry/sdk-trace-base';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { PgInstrumentation } from '@opentelemetry/instrumentation-pg';
import { PinoInstrumentation } from '@opentelemetry/instrumentation-pino';
import { diag, DiagConsoleLogger, DiagLogLevel } from '@opentelemetry/api';

const SERVICE_NAME = process.env.OTEL_SERVICE_NAME || 'self-healing-agent';

function startTelemetry(): void {
  if (
    process.env.OTEL_SDK_DISABLED === 'true' ||
    process.env.OTEL_SDK_DISABLED === '1'
  ) {
    console.error(`[telemetry] OTEL_SDK_DISABLED set — tracing off (${SERVICE_NAME})`);
    return;
  }

  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.ERROR);

  // We only wire a traceExporter below; NodeSDK auto-configures metrics AND
  // logs readers independently (each its own OTEL_*_EXPORTER env var), and
  // both default exporters read OTEL_EXPORTER_OTLP_ENDPOINT straight from
  // process.env (not the local `endpoint` const below), falling back to
  // localhost:4318 and spamming ECONNREFUSED. We export neither custom
  // metrics nor logs via OTel today, so disable both outright.
  if (process.env.OTEL_METRICS_EXPORTER === undefined) {
    process.env.OTEL_METRICS_EXPORTER = 'none';
  }
  if (process.env.OTEL_LOGS_EXPORTER === undefined) {
    process.env.OTEL_LOGS_EXPORTER = 'none';
  }

  const endpoint =
    process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://otel-collector:4318';

  const ratioArg = process.env.OTEL_TRACES_SAMPLER_ARG;
  const ratio =
    ratioArg !== undefined && ratioArg !== ''
      ? Number(ratioArg)
      : process.env.NODE_ENV === 'production'
        ? 0.2
        : 1.0;
  const safeRatio = Number.isFinite(ratio) ? Math.min(Math.max(ratio, 0), 1) : 1.0;

  const sdk = new NodeSDK({
    resource: resourceFromAttributes({ [ATTR_SERVICE_NAME]: SERVICE_NAME }),
    sampler: new ParentBasedSampler({
      root: new TraceIdRatioBasedSampler(safeRatio),
    }),
    traceExporter: new OTLPTraceExporter({
      url: `${endpoint.replace(/\/+$/, '')}/v1/traces`,
    }),
    instrumentations: [
      new HttpInstrumentation(),
      new PgInstrumentation(),
      new PinoInstrumentation(),
    ],
  });

  try {
    sdk.start();
    console.error(
      `[telemetry] OTel started service=${SERVICE_NAME} endpoint=${endpoint} ratio=${safeRatio}`,
    );
  } catch (err) {
    console.error('[telemetry] failed to start OTel SDK; continuing without tracing', err);
    return;
  }

  const shutdown = (signal: string): void => {
    sdk
      .shutdown()
      .catch((err) => {
        console.error('[telemetry] error during OTel shutdown', err);
      })
      .finally(() => {
        process.kill(process.pid, signal);
      });
  };
  process.once('SIGTERM', () => shutdown('SIGTERM'));
  process.once('SIGINT', () => shutdown('SIGINT'));
}

startTelemetry();
