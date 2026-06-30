import axios from 'axios';
import pino from 'pino';
import { LLMAnalysis } from './types.js';

const logger = pino({
  level: process.env.LOG_LEVEL || 'info',
  base: { service: 'self-healing-agent-github' },
});

const API = 'https://api.github.com';

/**
 * Opens a GitHub issue for a confirmed insight — the "action" half of the agent
 * (detection alone is useless if nobody sees it). Deduped by a hidden fingerprint
 * marker in the issue body so a recurring error never spawns duplicate issues.
 *
 * Entirely optional and best-effort: with no GITHUB_TOKEN/GITHUB_REPO set, or on
 * any API error, it logs and returns null without disturbing the main loop.
 */
export class GitHubActions {
  private readonly enabled: boolean;
  constructor(
    private readonly token: string,
    private readonly repo: string, // "owner/name"
  ) {
    this.enabled = Boolean(token && repo && repo.includes('/'));
    if (!this.enabled) {
      logger.info('GitHub action disabled (no GITHUB_TOKEN/GITHUB_REPO); insights saved to DB only');
    }
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  private headers() {
    return {
      Authorization: `Bearer ${this.token}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    };
  }

  private marker(fingerprint: string): string {
    return `self-healing-fingerprint:${fingerprint}`;
  }

  /** Returns the html_url of an existing OPEN issue for this fingerprint, or null. */
  private async findExisting(fingerprint: string): Promise<string | null> {
    const q = `repo:${this.repo} is:issue is:open in:body "${this.marker(fingerprint)}"`;
    const res = await axios.get(`${API}/search/issues`, {
      headers: this.headers(),
      params: { q, per_page: 1 },
      timeout: 10000,
    });
    const item = res.data?.items?.[0];
    return item?.html_url ?? null;
  }

  /**
   * Creates (or reuses) an issue for the insight. Returns the issue URL or null.
   */
  async openIssue(
    service: string,
    fingerprint: string,
    analysis: LLMAnalysis,
    errorMessage: string,
  ): Promise<string | null> {
    if (!this.enabled) return null;

    try {
      const existing = await this.findExisting(fingerprint);
      if (existing) {
        logger.info({ service, fingerprint, existing }, 'Issue already open for fingerprint; skipping create');
        return existing;
      }

      const title = `[self-healing] ${service}: ${truncate(analysis.root_cause, 80)}`;
      const body = [
        `**Service:** \`${service}\``,
        `**Severity:** \`${analysis.severity}\``,
        '',
        `### Root cause`,
        analysis.root_cause,
        '',
        `### Suggested fix`,
        analysis.suggested_fix,
        '',
        `### Log sample`,
        '```',
        truncate(errorMessage, 1500),
        '```',
        '',
        `<sub>Opened automatically by the self-healing agent. <!-- ${this.marker(fingerprint)} --></sub>`,
      ].join('\n');

      const res = await axios.post(
        `${API}/repos/${this.repo}/issues`,
        { title, body, labels: ['self-healing', analysis.severity] },
        { headers: this.headers(), timeout: 10000 },
      );
      const url = res.data?.html_url ?? null;
      logger.info({ service, fingerprint, url }, 'Opened GitHub issue for insight');
      return url;
    } catch (error) {
      logger.warn({ service, fingerprint, error: (error as Error).message }, 'Failed to open GitHub issue');
      return null;
    }
  }
}

function truncate(s: string, n: number): string {
  return s.length > n ? s.slice(0, n) + '…' : s;
}
