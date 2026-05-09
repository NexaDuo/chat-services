import { Pool } from 'pg';
import pino from 'pino';
import { LLMAnalysis } from './types.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'self-healing-agent-db' },
});

export class Database {
  constructor(private readonly pool: Pool) {}

  /**
   * Initializes the database and table if they don't exist.
   */
  async init(): Promise<void> {
    const client = await this.pool.connect();
    try {
      await client.query('CREATE EXTENSION IF NOT EXISTS pgcrypto');
      
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

  async isCooldownActive(fingerprint: string, cooldownHours: number): Promise<boolean> {
    const query = `SELECT 1 FROM insights WHERE fingerprint = $1 AND created_at > NOW() - interval '${cooldownHours} hours'`;
    const res = await this.pool.query(query, [fingerprint]);
    return (res.rowCount ?? 0) > 0;
  }

  async saveInsight(
    service: string, 
    log: string, 
    fingerprint: string, 
    analysis: LLMAnalysis, 
    metadata: any
  ): Promise<void> {
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
      await this.pool.query(query, values);
    } catch (error) {
      logger.error({ error: (error as Error).message }, 'Failed to save insight to Postgres');
      throw error;
    }
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}
