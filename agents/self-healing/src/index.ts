import axios from 'axios';
import { Pool } from 'pg';
import pino from 'pino';
import crypto from 'crypto';
import { z } from 'zod';
import { Database } from './db.js';
import { LLMAnalysis, LokiQueryResult } from './types.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'self-healing-agent' },
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
const COOLDOWN_HOURS = 24;

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});
const db = new Database(pool);

let difyApiKey = '';

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
    logger.warn('HANDOFF_SHARED_SECRET not set, cannot fetch remote config');
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
  const query = `{project="${project}", service!="self-healing-agent"} |~ "(?i)(error|fatal|panic|exception|traceback)"`;
  
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
    logger.warn('difyApiKey not set, skipping LLM analysis');
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

let running = true;
async function mainLoop(): Promise<void> {
  logger.info('Starting self-healing main loop');
  
  while (running) {
    try {
      const results = await queryLokiErrors();
      
      for (const result of results) {
        const service = result.stream.service || result.stream.container || 'unknown';
        
        const messages = result.values.map((v: [string, string]) => v[1]);
        const uniqueMessages = Array.from(new Set(messages));

        for (const message of uniqueMessages) {
          const fingerprint = getFingerprint(service, message);
          
          if (await db.isCooldownActive(fingerprint, COOLDOWN_HOURS)) {
            continue;
          }

          logger.info({ service, fingerprint }, 'Analyzing new error');
          const analysis = await analyzeWithErrorLLM(service, message);
          if (analysis) {
            await db.saveInsight(service, message, fingerprint, analysis, { loki_labels: result.stream });
            logger.info({ service, fingerprint }, 'Saved unique insight to database');
          }
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
