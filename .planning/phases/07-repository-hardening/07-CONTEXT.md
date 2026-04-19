# Phase 07: Repository Hardening for Public Release

## Goal
Harden the repository by addressing all security audit findings required to make the project safely public on GitHub. This includes secret rotation, removing insecure fallbacks, adding webhook authentication, and pinning container versions.

## Success Criteria
1. All hardcoded secrets removed from tracked files and replaced with dynamic environment variables.
2. Insecure default credential fallbacks removed from all services (fail fast instead).
3. Webhook authentication implemented for Chatwoot incoming requests.
4. All Docker images pinned to immutable versions or digests.
5. Inbound ports restricted and wildcard CORS removed.

## Reference
- Pending Todo: `.planning/todos/pending/2026-04-16-harden-repo-for-public-github-security.md`
- STATE.md Current Focus: Ready for Production Provisioning / GitHub Hardening
