import axios from 'axios';
import { Pool } from 'pg';
import pino from 'pino';
import crypto from 'crypto';
import { z } from 'zod';
import { trace, isSpanContextValid } from '@opentelemetry/api';
import { Database } from './db.js';
import { GitHubActions } from './github.js';
import { LLMAnalysis, LokiQueryResult } from './types.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'self-healing-agent' },
  // ISO 8601 timestamps so the `time` field matches the telemetry contract
  // (and the middleware's output) for consistent Promtail parsing.
  timestamp: () => `,"time":"${new Date().toISOString()}"`,
  // Inject the active OTel span context as trace_id/span_id so logs link to
  // traces in Grafana (matches the Loki derived field). No-op without a span.
  mixin() {
    const span = trace.getActiveSpan();
    if (!span) return {};
    const ctx = span.spanContext();
    if (!ctx || !isSpanContextValid(ctx)) return {};
    return { trace_id: ctx.traceId, span_id: ctx.spanId };
  },
});

const LOKI_URL = process.env.LOKI_URL || 'http://loki:3100';
const DIFY_API_URL = process.env.DIFY_API_URL || 'http://dify-api:5001/v1';
const MIDDLEWARE_URL = process.env.MIDDLEWARE_URL || 'http://middleware:4000';
const HANDOFF_SHARED_SECRET = process.env.HANDOFF_SHARED_SECRET || '';

if (!process.env.DATABASE_URL) {
  logger.error('FATAL: DATABASE_URL environment variable is required');
  process.exit(1);
}

const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '300000'); // 5 minutes
const COOLDOWN_HOURS = parseInt(process.env.COOLDOWN_HOURS || '24');
// Hard ceiling on LLM calls per cycle so a log storm can't blow the token budget.
const MAX_ANALYSES_PER_CYCLE = parseInt(process.env.MAX_ANALYSES_PER_CYCLE || '10');

// Severity gate for opening issues: only error/fatal by default (warnings/info
// are saved as insights but don't spam the issue tracker).
const SEVERITY_RANK: Record<string, number> = { info: 0, warning: 1, error: 2, fatal: 3 };
const ISSUE_MIN_SEVERITY = (process.env.ISSUE_MIN_SEVERITY || 'error').toLowerCase();

// Benign log lines that match the broad "error" regex but aren't worth an LLM
// call. Override/extend with SELF_HEALING_NOISE_REGEX. Keeps token spend on real
// problems (e.g. healthcheck noise, the OTel exporter retrying, 4xx access logs).
const DEFAULT_NOISE =
  '(GET|POST|HEAD).*(200|204|301|302)|healthcheck|/health|favicon|opentelemetry|OTLPExporter|:431[78]|deprecat';
const NOISE_REGEX = new RegExp(process.env.SELF_HEALING_NOISE_REGEX || DEFAULT_NOISE, 'i');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});
const db = new Database(pool);
const github = new GitHubActions(process.env.GITHUB_TOKEN || '', process.env.GITHUB_REPO || '');

let difyApiKey = '';
// Log the "no Dify key" degraded mode once, not on every error/loop iteration
// (the per-iteration spam is what polluted CI logs — issue #22).
let warnedNoDifyKey = false;

const AnalysisSchema = z.object({
  root_cause: z.string(),
  suggested_fix: z.string(),
  severity: z.string(),
});

/**
 * Fetches configuration from the middleware with retries.
 */
async function fetchConfig(retries = 5, delay = 5000): Promise<void> {
  if (!HANDOFF_SHARED_SECRET) {
    // Expected when running without the middleware config API (e.g. CI):
    // the agent degrades to detection-only. Info, not warn (issue #22).
    logger.info('HANDOFF_SHARED_SECRET not set; running without remote config (LLM analysis disabled)');
    return;
  }

  for (let i = 0; i < retries; i++) {
    try {
      const response = await axios.get(`${MIDDLEWARE_URL}/config`, {
        headers: {
          'Authorization': `Bearer ${HANDOFF_SHARED_SECRET}`,
        },
        timeout: 5000
      });

      if (response.data.dify?.selfHealingApiKey) {
        difyApiKey = response.data.dify.selfHealingApiKey;
        logger.info('Remote config fetched successfully');
        return;
      }
      logger.warn('Config fetched but dify.selfHealingApiKey is empty (set DIFY_SELF_HEALING_API_KEY in middleware.configs)');
      return;
    } catch (error) {
      const isLast = i === retries - 1;
      logger.warn({
        attempt: i + 1,
        error: (error as Error).message,
        nextRetryIn: isLast ? 0 : delay / 1000
      }, 'Failed to fetch config from middleware');

      if (!isLast) {
        await new Promise(resolve => setTimeout(resolve, delay));
        delay *= 2; // Exponential backoff
      }
    }
  }
}

/**
 * Normalizes log message for fingerprinting by removing timestamps/IDs.
 */
function getFingerprint(service: string, message: string): string {
  const normalized = message
    .replace(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*?\s/g, '<TS> ') // Timestamps
    .replace(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi, '<UUID>') // UUIDs
    .replace(/\d+/g, 'N') // Numbers
    .slice(0, 300); // Keep it short

  return crypto.createHash('sha256').update(`${service}:${normalized}`).digest('hex');
}

async function queryLokiErrors(): Promise<LokiQueryResult[]> {
  const end = Date.now() * 1000000;
  const start = (Date.now() - POLL_INTERVAL_MS) * 1000000;

  const project = process.env.COMPOSE_PROJECT_NAME || 'nexaduo';
  // Exclude our OWN logs by `container` (always present), not `service` — Promtail
  // derives `service` from the compose-service label, which isn't reliably set in
  // every deployment, so the agent was analyzing its own errors (a feedback loop).
  const query = `{project="${project}", container!~".*self-healing.*"} |~ "(?i)(error|fatal|panic|exception|traceback)"`;

  try {
    const response = await axios.get(`${LOKI_URL}/loki/api/v1/query_range`, {
      params: { query, start, end, limit: 100 },
    });
    return response.data.data.result as LokiQueryResult[];
  } catch (error) {
    logger.error({ error: (error as Error).message }, 'Failed to query Loki');
    return [];
  }
}

async function analyzeWithErrorLLM(service: string, logSnippet: string): Promise<LLMAnalysis | null> {
  if (!difyApiKey) {
    if (!warnedNoDifyKey) {
      logger.info('Dify API key not configured; skipping LLM analysis (logged once)');
      warnedNoDifyKey = true;
    }
    return null;
  }

  try {
    const response = await axios.post(`${DIFY_API_URL}/workflows/run`, {
      inputs: { service_name: service, log_content: logSnippet.slice(0, 2000) },
      response_mode: 'blocking',
      user: 'self-healing-agent',
    }, {
      headers: {
        'Authorization': `Bearer ${difyApiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000
    });

    const parsed = AnalysisSchema.safeParse(response.data.data.outputs);
    if (!parsed.success) {
      logger.error({ issues: parsed.error.issues }, 'Invalid analysis response from Dify');
      return null;
    }

    return parsed.data;
  } catch (error) {
    logger.error({ error: (error as Error).message }, 'Failed to call LLM via Dify');
    return null;
  }
}

/** True if the analysis severity meets the configured threshold for opening an issue. */
function meetsIssueThreshold(severity: string): boolean {
  const rank = SEVERITY_RANK[(severity || '').toLowerCase()] ?? SEVERITY_RANK.error;
  const min = SEVERITY_RANK[ISSUE_MIN_SEVERITY] ?? SEVERITY_RANK.error;
  return rank >= min;
}

let running = true;
async function mainLoop(): Promise<void> {
  logger.info(
    { pollMs: POLL_INTERVAL_MS, maxPerCycle: MAX_ANALYSES_PER_CYCLE, issuesEnabled: github.isEnabled() },
    'Starting self-healing main loop',
  );

  while (running) {
    let analyzedThisCycle = 0;
    try {
      const results = await queryLokiErrors();

      // Collect unique (service, message) candidates first, so the per-cycle cap
      // applies across all streams rather than starving later services.
      const candidates: { service: string; message: string; labels: any }[] = [];
      const seen = new Set<string>();
      for (const result of results) {
        const service = result.stream.service || result.stream.container || 'unknown';
        if (/self-healing/i.test(service)) continue; // defensive: never analyze ourselves
        for (const [, message] of result.values) {
          if (NOISE_REGEX.test(message)) continue; // skip benign noise before any LLM cost
          const key = `${service}::${message}`;
          if (seen.has(key)) continue;
          seen.add(key);
          candidates.push({ service, message, labels: result.stream });
        }
      }

      for (const { service, message, labels } of candidates) {
        if (analyzedThisCycle >= MAX_ANALYSES_PER_CYCLE) {
          logger.warn({ cap: MAX_ANALYSES_PER_CYCLE, remaining: candidates.length - analyzedThisCycle },
            'Hit per-cycle analysis cap; deferring remaining errors to next cycle');
          break;
        }

        const fingerprint = getFingerprint(service, message);

        // Recurring within cooldown → just bump the count, no LLM spend.
        if (await db.bumpIfRecent(fingerprint, COOLDOWN_HOURS)) {
          continue;
        }

        logger.info({ service, fingerprint }, 'Analyzing new error');
        analyzedThisCycle++;
        const analysis = await analyzeWithErrorLLM(service, message);
        if (!analysis) continue;

        const id = await db.saveInsight(service, message, fingerprint, analysis, { loki_labels: labels });
        logger.info({ service, fingerprint, severity: analysis.severity }, 'Saved unique insight to database');

        // Action: open a deduped GitHub issue for sufficiently severe insights.
        if (github.isEnabled() && meetsIssueThreshold(analysis.severity)) {
          const url = await github.openIssue(service, fingerprint, analysis, message);
          if (url) await db.setIssueUrl(id, url);
        }
      }
    } catch (err) {
      logger.error({ err }, 'Error in main loop iteration');
    }

    if (running) {
      await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));
    }
  }
}

// Graceful shutdown
process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, shutting down...');
  running = false;
  await db.close();
});

async function run(): Promise<void> {
  await db.init();
  await fetchConfig();
  await mainLoop();
}

run().catch(err => {
  logger.error({ err }, 'Fatal error in agent');
  process.exit(1);
});
