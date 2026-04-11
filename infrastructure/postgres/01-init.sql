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

SELECT 'CREATE DATABASE self_healing'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'self_healing')\gexec

SELECT 'CREATE DATABASE middleware'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'middleware')\gexec

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

-- ---------- middleware -------------------------------------------------------
\connect middleware
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS configs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key TEXT NOT NULL UNIQUE,
  value TEXT,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Pre-seed some default keys if needed
-- INSERT INTO configs (key, value) VALUES ('DIFY_SELF_HEALING_API_KEY', NULL) ON CONFLICT DO NOTHING;

-- ---------- self_healing -----------------------------------------------------
\connect self_healing
CREATE EXTENSION IF NOT EXISTS pgcrypto;
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
);

CREATE INDEX IF NOT EXISTS idx_insights_fingerprint ON insights(fingerprint);
CREATE INDEX IF NOT EXISTS idx_insights_service_created ON insights(service_name, created_at DESC);

-- ---------- evolution --------------------------------------------------------
\connect evolution
CREATE EXTENSION IF NOT EXISTS pgcrypto;
