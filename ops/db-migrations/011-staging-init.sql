-- =============================================================
-- SUPERSEDED on 2026-09-10 by ADR-007 (shared staging
-- super-database with per-project login roles). DO NOT RUN.
-- Kept as history. Staging uses a `<proj>_staging` LOGIN role
-- owning a schema of the same name; prod stays per project
-- with its tables in `public`.
-- https://www.interstellarai.net/mementos/007-staging-super-database-role-convention
-- =============================================================

-- =============================================================
-- 011: Staging DB initialization — all project schemas & roles
-- Run against: staging Supabase (consolidated staging instance)
-- Note: empty schemas — no data migration needed
-- =============================================================


-- -------------------------------------------------------------
-- Annie
-- -------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS annie;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'annie_app') THEN
    CREATE ROLE annie_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA annie TO annie_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA annie
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO annie_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA annie
  GRANT USAGE, SELECT ON SEQUENCES TO annie_app;


-- -------------------------------------------------------------
-- Reli
-- -------------------------------------------------------------

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


-- -------------------------------------------------------------
-- FilmDuel
-- -------------------------------------------------------------

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


-- -------------------------------------------------------------
-- Kindred
-- -------------------------------------------------------------

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


-- -------------------------------------------------------------
-- Lachesis
-- -------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS lachesis;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lachesis_app') THEN
    CREATE ROLE lachesis_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA lachesis TO lachesis_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA lachesis
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lachesis_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA lachesis
  GRANT USAGE, SELECT ON SEQUENCES TO lachesis_app;


-- =============================================================
-- Verify: all schemas created
-- =============================================================
-- SELECT schema_name FROM information_schema.schemata
--   WHERE schema_name IN ('annie', 'reli', 'filmduel', 'kindred', 'lachesis')
--   ORDER BY schema_name;

-- Connection string note:
-- The pooler ignores `options=-c search_path` in the URL, so the
-- pattern this file used to document never took effect. For staging,
-- ADR-007 has the connection string that works: authenticate as the
-- `<proj>_staging` role, whose own `search_path` selects the schema.
