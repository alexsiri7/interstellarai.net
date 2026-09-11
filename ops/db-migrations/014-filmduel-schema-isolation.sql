-- =============================================================
-- SUPERSEDED on 2026-09-10 by ADR-007 (shared staging
-- super-database with per-project login roles). DO NOT RUN.
-- Kept as history. Staging uses a `<proj>_staging` LOGIN role
-- owning a schema of the same name; prod stays per project
-- with its tables in `public`.
-- https://www.interstellarai.net/mementos/007-staging-super-database-role-convention
-- =============================================================

-- =============================================================
-- 014: FilmDuel schema isolation — PROD DB
-- Run against: prod Supabase (default / consolidated DB)
-- Prerequisites: FilmDuel tables must be migrated one-shot first
-- =============================================================

-- Step 1: Discover existing FilmDuel tables before moving
-- Run:  \dt public.*
-- Identify all filmduel-owned tables and list them below.

-- Step 2: Create filmduel schema
CREATE SCHEMA IF NOT EXISTS filmduel;

-- Step 3: Move tables into filmduel schema
-- Repeat for each filmduel-owned table discovered in Step 1.
-- Run all moves inside a single transaction to avoid FK issues:
--
-- BEGIN;
-- ALTER TABLE public.{table1} SET SCHEMA filmduel;
-- ALTER TABLE public.{table2} SET SCHEMA filmduel;
-- ...
-- COMMIT;

-- Step 4: Create scoped role
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'filmduel_app') THEN
    CREATE ROLE filmduel_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA filmduel TO filmduel_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA filmduel TO filmduel_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA filmduel TO filmduel_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA filmduel
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO filmduel_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA filmduel
  GRANT USAGE, SELECT ON SEQUENCES TO filmduel_app;

-- Step 5: Assign the app user to the role
-- Uncomment and adjust for your connection user:
-- GRANT filmduel_app TO authenticator;
-- Or: GRANT filmduel_app TO {connection_user};

-- Verify: tables now in filmduel schema
-- \dt filmduel.*


-- =============================================================
-- 014: FilmDuel schema isolation — STAGING DB
-- Run against: staging Supabase (consolidated staging instance)
-- Note: empty schema — no data migration needed
-- =============================================================

CREATE SCHEMA IF NOT EXISTS filmduel;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'filmduel_app') THEN
    CREATE ROLE filmduel_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA filmduel TO filmduel_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA filmduel
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO filmduel_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA filmduel
  GRANT USAGE, SELECT ON SEQUENCES TO filmduel_app;

-- Connection string note:
-- The pooler ignores `options=-c search_path` in the URL, so the
-- pattern this file used to document never took effect. For staging,
-- ADR-007 has the connection string that works: authenticate as the
-- `<proj>_staging` role, whose own `search_path` selects the schema.
