-- =============================================================
-- 017: Reli schema isolation — PROD DB
-- Run against: prod Supabase (default / consolidated DB)
-- Prerequisites: Reli tables must be migrated one-shot first
-- =============================================================

-- Step 1: Discover existing Reli tables before moving
-- Run:  \dt public.*
-- Identify all reli-owned tables and list them below.

-- Step 2: Create reli schema
CREATE SCHEMA IF NOT EXISTS reli;

-- Step 3: Move tables into reli schema
-- Repeat for each reli-owned table discovered in Step 1.
-- Run all moves inside a single transaction to avoid FK issues:
--
-- BEGIN;
-- ALTER TABLE public.{table1} SET SCHEMA reli;
-- ALTER TABLE public.{table2} SET SCHEMA reli;
-- ...
-- COMMIT;

-- Step 4: Create scoped role
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'reli_app') THEN
    CREATE ROLE reli_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA reli TO reli_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA reli TO reli_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA reli TO reli_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA reli
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO reli_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA reli
  GRANT USAGE, SELECT ON SEQUENCES TO reli_app;

-- Step 5: Assign the app user to the role
-- Uncomment and adjust for your connection user:
-- GRANT reli_app TO authenticator;
-- Or: GRANT reli_app TO {connection_user};

-- Verify: tables now in reli schema
-- \dt reli.*
-- SELECT count(*) FROM reli.things;


-- =============================================================
-- 017: Reli schema isolation — STAGING DB
-- Run against: staging Supabase (consolidated staging instance)
-- Note: empty schema — no data migration needed
-- =============================================================

CREATE SCHEMA IF NOT EXISTS reli;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'reli_app') THEN
    CREATE ROLE reli_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA reli TO reli_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA reli
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO reli_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA reli
  GRANT USAGE, SELECT ON SEQUENCES TO reli_app;

-- Connection string note:
-- After running this migration, update the Reli app's DATABASE_URL
-- to include the search_path. Examples:
--   Prisma:    postgresql://user:pass@host:5432/postgres?schema=reli
--   Direct:    postgresql://user:pass@host:5432/postgres?options=-csearch_path%3Dreli
