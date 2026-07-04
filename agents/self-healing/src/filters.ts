import { readFileSync } from 'fs';
import { join } from 'path';

/**
 * Noise filtering for the self-healing agent (issue #131).
 *
 * The agent's Loki query greps for lines matching `(?i)(error|fatal|panic|
 * exception|traceback)`, which also catches INFO lines that merely *mention*
 * those words, operator psql typos, and known non-actionable classes. Filing
 * an insight for those pollutes the board with false/expected issues.
 *
 * `shouldFileIssue()` gates every candidate line before it is analyzed/saved:
 *   1. Severity gate — only real `error`/`fatal`/`panic` lines pass; INFO /
 *      DEBUG / WARN / NOTICE lines are dropped (verified false positive: #99).
 *   2. Interactive-operator gate — Postgres schema/syntax errors from ad-hoc
 *      interactive psql/CLI sessions (not parameterized app queries) are
 *      dropped (verified false positive: #82).
 *   3. Ignore-rules gate — a versioned, data-driven allowlist of known
 *      non-actionable classes (absent Enterprise controllers on CE #63,
 *      intentionally-unconfigured SMTP #94). See ignore-rules.json.
 *
 * All rules are versioned in-repo so a from-scratch bootstrap reproduces the
 * exact filtering (AGENTS.md: reproducibility is non-negotiable).
 */

export type Severity = 'debug' | 'info' | 'warn' | 'error' | 'fatal' | 'unknown';

export interface IgnoreRule {
  id: string;
  reason: string;
  /** Optional regex tested (case-insensitive) against the Loki `service` label. */
  service?: string;
  /** Regexes (case-insensitive); ALL must match the log message for a hit. */
  patterns: string[];
}

export interface FilterDecision {
  file: boolean;
  /** Machine-readable reason a line was suppressed (for structured logging). */
  reason?: string;
}

/**
 * Best-effort extraction of a log line's own severity. Returns `unknown` when
 * no level can be positively identified — callers treat `unknown` as "let it
 * through" so real errors that lack a parseable level are never dropped.
 */
export function extractSeverity(line: string): Severity {
  const text = line.trim();

  // 1. Structured JSON logs (pino/middleware/this agent): numeric or string level.
  //    Only attempt a parse when it looks like an object to avoid cost on plain lines.
  if (text.startsWith('{')) {
    try {
      const obj = JSON.parse(text);
      const lvl = obj.level ?? obj.severity ?? obj.lvl;
      if (typeof lvl === 'number') {
        // pino numeric levels: 10 trace, 20 debug, 30 info, 40 warn, 50 error, 60 fatal.
        if (lvl >= 60) return 'fatal';
        if (lvl >= 50) return 'error';
        if (lvl >= 40) return 'warn';
        if (lvl >= 20) return lvl >= 30 ? 'info' : 'debug';
        return 'debug';
      }
      if (typeof lvl === 'string') {
        const s = normalizeLevelWord(lvl);
        if (s !== 'unknown') return s;
      }
    } catch {
      // fall through to text heuristics
    }
  }

  // 2. Rails logger: `I, [ts] INFO -- : ...` / `E, [ts] ERROR -- : ...`.
  const rails = text.match(/^[DIWEF],\s*\[[^\]]*\]\s+(DEBUG|INFO|WARN|ERROR|FATAL)\b/);
  if (rails) return normalizeLevelWord(rails[1]);

  // 3. Postgres server log severities: `ERROR:`, `FATAL:`, `PANIC:`, `LOG:`,
  //    `WARNING:`, `NOTICE:`, `STATEMENT:`, `DETAIL:`, `HINT:`, `CONTEXT:`.
  const pg = text.match(/\b(ERROR|FATAL|PANIC|WARNING|NOTICE|LOG|DEBUG\d?|STATEMENT|DETAIL|HINT|CONTEXT|INFO):/);
  if (pg) {
    const kw = pg[1];
    if (kw === 'PANIC' || kw === 'FATAL') return 'fatal';
    if (kw === 'ERROR') return 'error';
    if (kw === 'WARNING') return 'warn';
    // LOG/NOTICE/INFO/STATEMENT/DETAIL/HINT/CONTEXT/DEBUG are non-actionable.
    if (kw.startsWith('DEBUG')) return 'debug';
    return 'info';
  }

  // 4. key=value logs (traefik/loki/promtail/grafana): `level=info` / `lvl=error`.
  const kv = text.match(/\b(?:level|lvl|severity)=("?)(trace|debug|info|warn(?:ing)?|error|err|fatal|panic|critical)\1/i);
  if (kv) return normalizeLevelWord(kv[2]);

  return 'unknown';
}

function normalizeLevelWord(word: string): Severity {
  switch (word.trim().toLowerCase()) {
    case 'trace':
    case 'debug':
      return 'debug';
    case 'info':
    case 'notice':
      return 'info';
    case 'warn':
    case 'warning':
      return 'warn';
    case 'err':
    case 'error':
      return 'error';
    case 'fatal':
    case 'panic':
    case 'critical':
      return 'fatal';
    default:
      return 'unknown';
  }
}

/**
 * True when a Postgres error almost certainly originates from an ad-hoc
 * interactive psql/CLI session by a human operator rather than an application
 * code path. Application ORM statements are always parameterized (`$1`) and
 * carry marginalia comments (`/*application:Chatwoot...*​/`); a literal,
 * unparameterized statement that fails with a schema/syntax error is a human
 * typing SQL (verified false positive: #82 — `select name, value from
 * installation_configs` where the real column is `serialized_value`).
 */
export function isInteractiveOperatorSession(service: string, message: string): boolean {
  const svc = service || '';
  const isPostgres = /postgres|psql|pgbouncer/i.test(svc);

  // Explicit psql client markers (present when log_line_prefix includes %a).
  // NOTE: `[unknown]` is deliberately NOT a marker — it is a normal
  // log_line_prefix artifact (unset user/db/app) that also appears on genuine
  // Postgres errors (auth failures, `PG::ConnectionBad`, deadlocks), so keying
  // off it would over-suppress real service failures.
  if (/application_name\s*=\s*psql|\bapp(?:lication)?\s*=\s*['"]?psql\b/i.test(message)) {
    return true;
  }

  if (!isPostgres) return false;

  // Operator-typo signatures on ad-hoc SQL.
  const schemaTypo = /(column|relation|function|operator)\s+"[^"]*"\s+does not exist|syntax error at or near|column\s+".*"\s+does not exist/i.test(message);
  if (!schemaTypo) return false;

  // Application queries are parameterized and/or carry a marginalia comment.
  const looksParameterized = /\$\d+/.test(message);
  const hasMarginalia = /\/\*\s*application:/i.test(message);
  if (looksParameterized || hasMarginalia) return false;

  return true;
}

/**
 * Returns the first ignore rule that matches, or null. A rule matches when its
 * (optional) `service` regex matches the service label AND every `patterns`
 * regex matches the message (all case-insensitive).
 */
export function matchIgnoreRule(
  service: string,
  message: string,
  rules: IgnoreRule[],
): IgnoreRule | null {
  for (const rule of rules) {
    if (rule.service && !new RegExp(rule.service, 'i').test(service || '')) continue;
    const patterns = rule.patterns || [];
    if (patterns.length === 0) continue;
    if (patterns.every((p) => new RegExp(p, 'i').test(message))) return rule;
  }
  return null;
}

/**
 * The single gate the main loop calls. Returns `{ file: false, reason }` when a
 * line must NOT become an insight/board issue.
 */
export function shouldFileIssue(
  service: string,
  message: string,
  rules: IgnoreRule[],
): FilterDecision {
  // 1. Severity gate — only real error/fatal lines file. `unknown` passes
  //    through so we never drop a genuine error that lacks a parseable level.
  const severity = extractSeverity(message);
  if (severity === 'info' || severity === 'debug' || severity === 'warn') {
    return { file: false, reason: `non-actionable-severity:${severity}` };
  }

  // 2. Interactive operator psql/CLI session.
  if (isInteractiveOperatorSession(service, message)) {
    return { file: false, reason: 'interactive-operator-session' };
  }

  // 3. Versioned ignore/allowlist for known non-actionable classes.
  const rule = matchIgnoreRule(service, message, rules);
  if (rule) {
    return { file: false, reason: `ignore-rule:${rule.id}` };
  }

  return { file: true };
}

/**
 * Loads the versioned ignore rules from ignore-rules.json (repo-root of the
 * agent, resolved relative to this module so it works in both `src` and `dist`).
 * Override the path with IGNORE_RULES_PATH. On any failure it returns an empty
 * rule set (the severity + interactive gates still apply) and lets the caller log.
 */
export function loadIgnoreRules(pathOverride?: string): IgnoreRule[] {
  // CommonJS build: __dirname is dist/ at runtime and src/ under vitest, so the
  // sibling ignore-rules.json is always one level up (see Dockerfile COPY).
  const path =
    pathOverride ||
    process.env.IGNORE_RULES_PATH ||
    join(__dirname, '..', 'ignore-rules.json');
  const raw = readFileSync(path, 'utf8');
  const parsed = JSON.parse(raw);
  const rules = Array.isArray(parsed) ? parsed : parsed.rules;
  if (!Array.isArray(rules)) throw new Error('ignore-rules.json: expected an array or { rules: [] }');
  return rules as IgnoreRule[];
}
