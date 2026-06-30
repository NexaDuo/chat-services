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
          github_issue_url TEXT,
          metadata JSONB
        )
      `);

      // Converge existing tables (created before github_issue_url existed).
      await client.query('ALTER TABLE insights ADD COLUMN IF NOT EXISTS github_issue_url TEXT');

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
   * If an insight with this fingerprint was already analyzed within the cooldown
   * window, bump its occurrence_count and return true (caller should SKIP the
   * expensive LLM analysis). Returns false when it's a genuinely new error that
   * should be analyzed. This replaces a plain "skip" so recurring errors still
   * accrue a useful count without spending tokens on every repeat.
   */
  async bumpIfRecent(fingerprint: string, cooldownHours: number): Promise<boolean> {
    const query = `
      UPDATE insights
         SET occurrence_count = occurrence_count + 1
       WHERE id = (
         SELECT id FROM insights
          WHERE fingerprint = $1 AND created_at > NOW() - ($2 || ' hours')::interval
          ORDER BY created_at DESC
          LIMIT 1
       )
      RETURNING id
    `;
    const res = await this.pool.query(query, [fingerprint, String(cooldownHours)]);
    return (res.rowCount ?? 0) > 0;
  }

  async saveInsight(
    service: string,
    log: string,
    fingerprint: string,
    analysis: LLMAnalysis,
    metadata: any
  ): Promise<string> {
    const query = `
      INSERT INTO insights (service_name, error_message, root_cause, suggested_fix, severity, fingerprint, metadata)
      VALUES ($1, $2, $3, $4, $5, $6, $7)
      RETURNING id
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
      const res = await this.pool.query(query, values);
      return res.rows[0].id as string;
    } catch (error) {
      logger.error({ error: (error as Error).message }, 'Failed to save insight to Postgres');
      throw error;
    }
  }

  /** Records the GitHub issue opened for an insight (best-effort, non-fatal). */
  async setIssueUrl(id: string, url: string): Promise<void> {
    try {
      await this.pool.query('UPDATE insights SET github_issue_url = $2 WHERE id = $1', [id, url]);
    } catch (error) {
      logger.warn({ error: (error as Error).message }, 'Failed to record GitHub issue URL');
    }
  }

  async close(): Promise<void> {
    await this.pool.end();
  }
}
