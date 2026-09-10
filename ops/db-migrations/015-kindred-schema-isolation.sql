-- =============================================================
-- SUPERSEDED on 2026-09-10 by ADR-007 (shared staging
-- super-database with per-project login roles). DO NOT RUN.
-- Kept as history. Staging uses a `<proj>_staging` LOGIN role
-- owning a schema of the same name; prod stays per project
-- with its tables in `public`.
-- https://www.interstellarai.net/mementos/007-staging-super-database-role-convention
-- =============================================================

-- =============================================================
-- 015: Kindred schema isolation — PROD DB
-- Run against: prod Supabase (default / consolidated DB)
-- Prerequisites: Kindred tables must be migrated one-shot first
-- =============================================================

-- Step 1: Discover existing Kindred tables before moving
-- Run:  \dt public.*
-- Identify all kindred-owned tables and list them below.

-- Step 2: Create kindred schema
CREATE SCHEMA IF NOT EXISTS kindred;

-- Step 3: Move tables into kindred schema
-- Repeat for each kindred-owned table discovered in Step 1.
-- Run all moves inside a single transaction to avoid FK issues:
--
-- BEGIN;
-- ALTER TABLE public.{table1} SET SCHEMA kindred;
-- ALTER TABLE public.{table2} SET SCHEMA kindred;
-- ...
-- COMMIT;

-- Step 4: Create scoped role
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kindred_app') THEN
    CREATE ROLE kindred_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA kindred TO kindred_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA kindred TO kindred_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA kindred TO kindred_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kindred
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kindred_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kindred
  GRANT USAGE, SELECT ON SEQUENCES TO kindred_app;

-- Step 5: Assign the app user to the role
-- Uncomment and adjust for your connection user:
-- GRANT kindred_app TO authenticator;
-- Or: GRANT kindred_app TO {connection_user};

-- Verify: tables now in kindred schema
-- \dt kindred.*


-- =============================================================
-- 015: Kindred schema isolation — STAGING DB
-- Run against: staging Supabase (consolidated staging instance)
-- Note: empty schema — no data migration needed
-- =============================================================

CREATE SCHEMA IF NOT EXISTS kindred;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'kindred_app') THEN
    CREATE ROLE kindred_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA kindred TO kindred_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kindred
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO kindred_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA kindred
  GRANT USAGE, SELECT ON SEQUENCES TO kindred_app;

-- Connection string note:
-- The pooler ignores `options=-c search_path` in the URL, so the
-- pattern this file used to document never took effect. For staging,
-- ADR-007 has the connection string that works: authenticate as the
-- `<proj>_staging` role, whose own `search_path` selects the schema.
