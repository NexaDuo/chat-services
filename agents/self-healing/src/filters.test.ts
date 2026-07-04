import { describe, test, expect } from 'vitest';
import {
  extractSeverity,
  isInteractiveOperatorSession,
  matchIgnoreRule,
  shouldFileIssue,
  loadIgnoreRules,
  IgnoreRule,
} from './filters.js';

// Regression guards for the self-healing noise filter (issue #131). Each block
// pins a verified false-positive class so the agent stops filing it. This logic
// lives in the Loki->Dify->insight path (server-side, no browser flow), so it is
// covered by these unit assertions rather than the Playwright suite.

// The real, versioned rules that ship in the image.
const rules = loadIgnoreRules();

describe('extractSeverity', () => {
  test('Rails INFO line is info even when it mentions error-ish words (#99)', () => {
    const line =
      'I, [2026-07-01T03:47:03.123 #7]  INFO -- : [ActiveJob] [ActionCableBroadcastJob] [uuid] Performing ActionCableBroadcastJob (notification.updated error channel)';
    expect(extractSeverity(line)).toBe('info');
  });

  test('Rails ERROR line is error', () => {
    const line = 'E, [2026-07-01T03:47:03.123 #7] ERROR -- : NoMethodError: undefined method';
    expect(extractSeverity(line)).toBe('error');
  });

  test('Postgres ERROR: is error, LOG: is info', () => {
    expect(extractSeverity('2026-06-30 10:46:10 UTC ERROR:  column "value" does not exist')).toBe('error');
    expect(extractSeverity('2026-06-30 10:46:10 UTC LOG:  statement: select 1')).toBe('info');
    expect(extractSeverity('2026-06-30 10:46:10 UTC FATAL:  the database system is shutting down')).toBe('fatal');
  });

  test('pino JSON numeric level maps correctly', () => {
    expect(extractSeverity('{"level":30,"msg":"handled error gracefully"}')).toBe('info');
    expect(extractSeverity('{"level":50,"msg":"boom"}')).toBe('error');
  });

  test('key=value traefik-style level', () => {
    expect(extractSeverity('time="..." level=info msg="request error path"')).toBe('info');
    expect(extractSeverity('time="..." level=error msg="upstream down"')).toBe('error');
  });

  test('unparseable line is unknown (fails open)', () => {
    expect(extractSeverity('some raw error with a traceback and no level marker')).toBe('unknown');
  });
});

describe('isInteractiveOperatorSession (#82)', () => {
  test('interactive psql column typo (unparameterized) is suppressed', () => {
    const msg = 'ERROR:  column "value" does not exist at character 14 STATEMENT:  select name, value from installation_configs';
    expect(isInteractiveOperatorSession('postgres', msg)).toBe(true);
  });

  test('parameterized ORM query failing is NOT treated as interactive', () => {
    const msg = 'ERROR:  column "value" does not exist STATEMENT:  SELECT * FROM x WHERE id = $1 /*application:Chatwoot*/';
    expect(isInteractiveOperatorSession('postgres', msg)).toBe(false);
  });

  test('non-postgres service is never an operator session (unless explicit marker)', () => {
    const msg = 'ERROR: column "value" does not exist';
    expect(isInteractiveOperatorSession('chatwoot', msg)).toBe(false);
  });

  // Regression: `[unknown]` is a normal log_line_prefix artifact (unset
  // user/db/app), NOT an interactive-session signal. A genuine app-caused
  // Postgres error logged with `[unknown]` must NOT be treated as interactive,
  // otherwise this filter would silently drop real failures (the over-
  // suppression this PR exists to prevent).
  test('genuine Postgres error containing [unknown] is NOT an operator session', () => {
    const constraint =
      '2026-07-04 10:00:00 UTC [12345] [unknown]@[unknown] ERROR:  duplicate key value violates unique constraint "index_users_on_email"';
    expect(isInteractiveOperatorSession('postgres', constraint)).toBe(false);

    const connBad =
      '2026-07-04 10:00:00 UTC [12345] [unknown]@[unknown] FATAL:  PG::ConnectionBad: could not connect to server';
    expect(isInteractiveOperatorSession('postgres', connBad)).toBe(false);
  });

  test('interactive typo still detected even with [unknown] prefix', () => {
    const msg =
      '2026-06-30 10:46:10 UTC [999] [unknown]@[unknown] ERROR:  column "value" does not exist at character 14 STATEMENT:  select name, value from installation_configs';
    expect(isInteractiveOperatorSession('postgres', msg)).toBe(true);
  });
});

describe('matchIgnoreRule (versioned allowlist)', () => {
  test('absent Enterprise controller on CE is matched (#63)', () => {
    const msg =
      'ActionController::RoutingError (uninitialized constant Api::V1::Accounts::CustomRolesController)';
    const hit = matchIgnoreRule('chatwoot', msg, rules);
    expect(hit?.id).toBe('chatwoot-enterprise-controller-absent-on-ce');
  });

  test('unconfigured SMTP EPIPE is matched (#94)', () => {
    const msg =
      'ERROR -- : [ActiveJob] MailDeliveryJob failed with Errno::EPIPE: Broken pipe';
    const hit = matchIgnoreRule('chatwoot', msg, rules);
    expect(hit?.id).toBe('smtp-unconfigured-mail-delivery-epipe');
  });

  test('a genuine error does not match any ignore rule', () => {
    const msg = 'ERROR -- : PG::ConnectionBad: could not connect to server';
    expect(matchIgnoreRule('chatwoot', msg, rules)).toBeNull();
  });

  test('rule requires ALL patterns to match', () => {
    const custom: IgnoreRule[] = [{ id: 'x', reason: 'r', patterns: ['foo', 'bar'] }];
    expect(matchIgnoreRule('svc', 'only foo here', custom)).toBeNull();
    expect(matchIgnoreRule('svc', 'foo and bar', custom)?.id).toBe('x');
  });
});

describe('shouldFileIssue — end-to-end gate', () => {
  test('#99 INFO broadcast line does NOT file', () => {
    const line =
      'I, [2026-07-01T03:47:03.123 #7]  INFO -- : [ActiveJob] [ActionCableBroadcastJob] Performing (notification serialization error path)';
    expect(shouldFileIssue('chatwoot-sidekiq', line, rules)).toEqual({
      file: false,
      reason: 'non-actionable-severity:info',
    });
  });

  test('#82 interactive psql typo does NOT file', () => {
    const line =
      'ERROR:  column "value" does not exist at character 14 STATEMENT:  select name, value from installation_configs';
    expect(shouldFileIssue('postgres', line, rules)).toEqual({
      file: false,
      reason: 'interactive-operator-session',
    });
  });

  test('#63 absent EE controller does NOT file', () => {
    const line =
      'ActionController::RoutingError (uninitialized constant Api::V1::Accounts::CustomRolesController)';
    const d = shouldFileIssue('chatwoot', line, rules);
    expect(d.file).toBe(false);
    expect(d.reason).toBe('ignore-rule:chatwoot-enterprise-controller-absent-on-ce');
  });

  test('#94 unconfigured SMTP EPIPE does NOT file', () => {
    const line = 'E, [ts] ERROR -- : MailDeliveryJob raised Errno::EPIPE: Broken pipe';
    const d = shouldFileIssue('chatwoot-sidekiq', line, rules);
    expect(d.file).toBe(false);
    expect(d.reason).toBe('ignore-rule:smtp-unconfigured-mail-delivery-epipe');
  });

  test('a genuine service error DOES file', () => {
    const line = 'E, [ts] ERROR -- : PG::ConnectionBad: could not connect to server: Connection refused';
    expect(shouldFileIssue('chatwoot', line, rules)).toEqual({ file: true });
  });

  test('genuine Postgres error with [unknown] prefix STILL files (not over-suppressed)', () => {
    const constraint =
      '2026-07-04 10:00:00 UTC [12345] [unknown]@[unknown] ERROR:  duplicate key value violates unique constraint "index_users_on_email"';
    expect(shouldFileIssue('postgres', constraint, rules)).toEqual({ file: true });

    const connBad =
      '2026-07-04 10:00:00 UTC [12345] [unknown]@[unknown] FATAL:  PG::ConnectionBad: could not connect to server';
    expect(shouldFileIssue('postgres', connBad, rules)).toEqual({ file: true });
  });

  test('an unparseable genuine error still files (fails open)', () => {
    const line = 'panic: runtime error: invalid memory address or nil pointer dereference';
    expect(shouldFileIssue('some-go-service', line, rules)).toEqual({ file: true });
  });
});
