/**
 * Fail-loud gate for missing/unusable remote config (issue #152).
 *
 * The self-healing agent needs `dify.selfHealingApiKey` from the Middleware
 * Config API to perform LLM root-cause analysis. Historically it degraded to
 * detection-only *silently* whenever that config was unavailable (issue #22
 * made that the deliberate CI/dev behaviour). That same silent degrade also
 * hid a real production wiring bug (HANDOFF_SHARED_SECRET missing from the
 * container) for an unknown period.
 *
 * This gate is a pure function so the CI/dev-vs-production decision can be
 * unit tested without booting the agent's DB pool / HTTP loop. It is
 * deliberately gated on an EXPLICIT opt-in flag, never inferred (e.g. from
 * NODE_ENV) — see AGENTS.md "Verify before you build".
 */
export type ConfigGateDecision = 'degrade' | 'fail';

export function decideMissingConfig(allowNoConfig: boolean): ConfigGateDecision {
  return allowNoConfig ? 'degrade' : 'fail';
}
