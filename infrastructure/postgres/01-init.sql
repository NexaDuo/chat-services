-- =============================================================================
-- NexaDuo chat-services — Postgres bootstrap
-- -----------------------------------------------------------------------------
-- Runs once, on the very first boot of the Postgres container (the default
-- Docker image executes every file in /docker-entrypoint-initdb.d/ only if the
-- data directory is empty).
--
-- Responsibilities:
--   1. Create one logical database per app (chatwoot / dify / evolution)
--      using a `SELECT ... \gexec` guard so this script is idempotent even if
--      someone re-runs it manually inside psql.
--   2. Install required extensions in each database.
--
-- Notes:
--   - The owner is the default POSTGRES_USER passed to the container; each
--     app then manages its own schema with that user.
--   - `vector` requires the `pgvector/pgvector:pg16` image (ships the .so).
-- =============================================================================

\set ON_ERROR_STOP on

SELECT 'CREATE DATABASE chatwoot'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chatwoot')\gexec

SELECT 'CREATE DATABASE dify'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dify')\gexec

SELECT 'CREATE DATABASE evolution'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'evolution')\gexec

SELECT 'CREATE DATABASE dify_plugin'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dify_plugin')\gexec

-- ---------- chatwoot ---------------------------------------------------------
\connect chatwoot
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ---------- dify -------------------------------------------------------------
\connect dify
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- dify_plugin ------------------------------------------------------
\connect dify_plugin
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------- evolution --------------------------------------------------------
\connect evolution
CREATE EXTENSION IF NOT EXISTS pgcrypto;
