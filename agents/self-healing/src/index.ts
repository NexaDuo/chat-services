import axios from 'axios';
import { Pool } from 'pg';
import pino from 'pino';
import crypto from 'crypto';

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

let difyApiKey = '';
const POLL_INTERVAL_MS = parseInt(process.env.POLL_INTERVAL_MS || '300000'); // 5 minutes
const COOLDOWN_HOURS = 24;

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
});

/**
 * Fetches configuration from the middleware with retries.
 */
async function fetchConfig(retries = 5, delay = 5000) {
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

interface LLMAnalysis {
  root_cause: string;
  suggested_fix: string;
  severity: string;
}

/**
 * Initializes the database and table if they don't exist.
 * This ensures the agent works even on existing volumes.
 */
async function initDb() {
  const client = await pool.connect();
  try {
    await client.query('CREATE EXTENSION IF NOT EXISTS pgcrypto');
    
    // Ensure table exists (though 01-init.sql handles it, we keep it for extra safety)
    await client.query(`
      CREATE TABLE IF NOT EXISTS insights (
        id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
        service_name TEXT NOT NULL,
        error_message TEXT,
        stack_trace TEXT,
        root_cause TEXT,
        suggested_fix TEXT,
        severity TEXT,
        fingerprint TEXT,
        occurrence_count INT DEFAULT 1,
        metadata JSONB
      )
    `);

    await client.query('CREATE INDEX IF NOT EXISTS idx_insights_fingerprint ON insights(fingerprint)');
    await client.query('CREATE INDEX IF NOT EXISTS idx_insights_service_created ON insights(service_name, created_at DESC)');
    
    logger.info('Database schema verified');
  } catch (err) {
    logger.error({ err }, 'Failed to initialize database schema');
    throw err;
  } finally {
    client.release();
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

async function isCooldownActive(fingerprint: string): Promise<boolean> {
  const query = `SELECT 1 FROM insights WHERE fingerprint = $1 AND created_at > NOW() - interval '${COOLDOWN_HOURS} hours'`;
  const res = await pool.query(query, [fingerprint]);
  return (res.rowCount ?? 0) > 0;
}

async function queryLokiErrors() {
  const end = Date.now() * 1000000;
  const start = (Date.now() - POLL_INTERVAL_MS) * 1000000;
  
  // Query by project label or container name prefix for stability
  const project = process.env.COMPOSE_PROJECT_NAME || 'nexaduo';
  const query = `{project="${project}", service!="self-healing-agent"} |~ "(?i)(error|fatal|panic|exception|traceback)"`;
  
  try {
    const response = await axios.get(`${LOKI_URL}/loki/api/v1/query_range`, {
      params: { query, start, end, limit: 100 },
    });
    return response.data.data.result;
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
      inputs: { service_name: service, log_content: logSnippet.slice(0, 2000) }, // Token safety
      response_mode: 'blocking',
      user: 'self-healing-agent',
    }, {
      headers: {
        'Authorization': `Bearer ${difyApiKey}`,
        'Content-Type': 'application/json',
      },
      timeout: 30000
    });

    return response.data.data.outputs as LLMAnalysis;
  } catch (error) {
    logger.error({ error: (error as Error).message }, 'Failed to call LLM via Dify');
    return null;
  }
}

async function saveInsight(service: string, log: string, fingerprint: string, analysis: LLMAnalysis, metadata: any) {
  const query = `
    INSERT INTO insights (service_name, error_message, root_cause, suggested_fix, severity, fingerprint, metadata)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
  `;
  const values = [
    service,
    log.slice(0, 1000), // Avoid massive rows
    analysis.root_cause || 'Unknown',
    analysis.suggested_fix || 'No fix proposed',
    analysis.severity || 'error',
    fingerprint,
    JSON.stringify(metadata),
  ];

  try {
    await pool.query(query, values);
    logger.info({ service, fingerprint }, 'Saved unique insight to database');
  } catch (error) {
    logger.error({ error: (error as Error).message }, 'Failed to save insight to Postgres');
  }
}

let running = true;
async function mainLoop() {
  logger.info('Starting self-healing main loop');
  
  while (running) {
    try {
      const results = await queryLokiErrors();
      
      for (const result of results) {
        const service = result.stream.service || result.stream.container || 'unknown';
        
        // Process unique log messages in this stream to save tokens
        const messages = result.values.map((v: [string, string]) => v[1]);
        const uniqueMessages = Array.from(new Set(messages));

        for (const message of uniqueMessages) {
          const fingerprint = getFingerprint(service, message as string);
          
          if (await isCooldownActive(fingerprint)) {
            continue;
          }

          logger.info({ service, fingerprint }, 'Analyzing new error');
          const analysis = await analyzeWithErrorLLM(service, message as string);
          if (analysis) {
            await saveInsight(service, message as string, fingerprint, analysis, { loki_labels: result.stream });
          }
        }
      }
    } catch (err) {
      logger.error({ err }, 'Error in main loop iteration');
    }
    
    // Sleep before next poll
    await new Promise(resolve => setTimeout(resolve, POLL_INTERVAL_MS));
  }
}

// Graceful shutdown
process.on('SIGTERM', () => {
  logger.info('SIGTERM received, shutting down...');
  running = false;
  pool.end();
});

async function run() {
  await initDb();
  await fetchConfig();
  await mainLoop();
}

run().catch(err => {
  logger.error({ err }, 'Fatal error in agent');
  process.exit(1);
});
