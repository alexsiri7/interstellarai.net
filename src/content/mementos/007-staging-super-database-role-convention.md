---
title: 'Shared staging super-database with per-project login roles'
number: 7
status: accepted
date: 2026-09-10
projects: [annie, reli, filmduel, kindred, lachesis]
supersedes: 6
---

This memento supersedes [ADR-006](/mementos/006-consolidated-db-architecture) in
full: prod was never consolidated onto a shared instance, and staging now uses
`<proj>_staging` login roles rather than `{project}_app` `NOLOGIN` roles.

## Context

ADR-006 decided two shared Supabase instances — one prod, one staging — each
holding a schema per project, with a `NOLOGIN` `{project}_app` role per schema
and a connection string carrying `?options=-csearch_path%3D{project}`.

The prod half of that was never executed. `ops/cron/backup-dbs.sh` reads five
separate secrets (`ANNIE_DB_URL`, `RELI_DB_URL`, `FILMDUEL_DB_URL`,
`KINDRED_DB_URL`, `LACHESIS_DB_URL`), and `ops/cron/README.md` states that
every project is dumped `--schema=public` because "all five keep their tables
there". Prod is five per-project databases, each with its tables in `public`.

The decision recorded in issue #66 on 2026-09-10 settles what happens next.
Wiring Reli to the shared staging project surfaced two facts about the live
infrastructure, both reported from Supabase and Railway configuration this
repository cannot reach:

- Reli's staging and production environments had been pointing at one database.
- The Supavisor pooler **silently discards `options=-c search_path` from the
  connection URL**. A connection made that way resolves against the default
  search path, not the project schema — so the recipe written into
  `ops/db-migrations/011,014,015,016,017-*.sql` does nothing, without erroring.

That is why the role convention below sets `search_path` on the role instead of
in the URL.

## Decision

### Staging is one shared super-database; prod is per project

Every project's staging environment uses the shared Supabase staging project
(`xhcfolmrdctmtqgqqxec`, eu-west-1). Production databases stay **per project**.

Schema-level isolation is what makes one shared staging database safe, carried
forward from ADR-006: a project's role holds privileges on its own schema and
nothing else, so a leaked or misconfigured staging credential cannot read
another project's tables.

### The role and schema convention

For each project on the staging super-database, as superuser:

```sql
CREATE ROLE <proj>_staging LOGIN PASSWORD '...';
GRANT <proj>_staging TO postgres;
CREATE SCHEMA <proj>_staging AUTHORIZATION <proj>_staging;
ALTER ROLE <proj>_staging SET search_path = <proj>_staging;
GRANT USAGE ON SCHEMA extensions TO <proj>_staging;
```

Two properties make this work:

- **The schema name equals the role name.** Postgres' default search path is
  `"$user", public`, so a session authenticated as `<proj>_staging` resolves
  into schema `<proj>_staging` with no URL parameter at all. The explicit
  `ALTER ROLE ... SET search_path` pins it even if the default changes.
- **The role has no privileges on `public`.** Projects cannot touch each
  other's tables, and a project cannot accidentally create tables in `public`.

### The connection string

Railway's staging `DATABASE_URL` authenticates **as the role itself** on the
session-mode pooler:

```
postgresql://<proj>_staging.<ref>:<password>@aws-1-eu-west-1.pooler.supabase.com:5432/postgres
```

Port 5432 is session mode and is required — Alembic runs DDL, which transaction
mode cannot carry. Do **not** append `options=-c search_path=...`: the pooler
ignores it, which is the failure this ADR exists to stop repeating. The search
path comes from the role.

### The Alembic baseline rule

A migration with `down_revision = None` — a clean baseline — requires dropping
`alembic_version` by hand before it runs, and **must never be deployed while
staging and prod share a database**. A baseline applied against a shared
database rewrites the migration history of both environments at once.

### Adopting the convention for a remaining project

- **reli** — done; the reference implementation. Its staging deploy is probed
  at `https://reli-staging.up.railway.app/healthz` by `pipeline-health-cron.sh`.
- **annie** — a known exception. Its staging deploy exists
  (`word-coach-annie-staging.up.railway.app/api/health`) and its staging tables
  live in `public` on the super-database, predating this convention. Moving it
  to `annie_staging` is not required by this ADR.
- **filmduel** — the staging deploy exists
  (`filmduel-staging.up.railway.app`); only the database side is missing. Run
  the role/schema SQL, then repoint the Railway staging `DATABASE_URL`.
- **kindred** — has no staging deploy yet (issue #34 closed with the Railway
  staging environment, Supabase staging setup and GitHub secrets outstanding).
  Create the Railway staging environment first, then the role and schema, then
  the `DATABASE_URL`, then add the health URL to `STAGING_DEPLOY_URLS` in
  `ops/cron/pipeline-health-cron.sh`.
- **lachesis** — same state and same sequence as kindred (issue #35 left its
  Railway, env and DNS steps manual).

Verify each one by connecting with the staging `DATABASE_URL` and checking that
`SHOW search_path` returns the project's schema, and that a `SELECT` against
another project's schema is refused.

## Consequences

- `ops/db-migrations/011-staging-init.sql` and the `014`–`017` schema-isolation
  runbooks are superseded and must not be run. They now carry a banner saying
  so. Running one today would create a `{project}` schema and a `{project}_app`
  `NOLOGIN` role that this convention does not use.
- ADR-006 is superseded in full. Every one of its decision bullets is replaced:
  prod is per project, staging schemas are `<proj>_staging`, the role logs in,
  and staging deliberately no longer mirrors prod.
- **Staging no longer mirrors prod's schema names** — staging is
  `<proj>_staging`, prod is `public`. Migration SQL must therefore be
  schema-agnostic (unqualified table names, resolved by the session's search
  path) to be valid in both environments. Hard-coding a schema name breaks one
  of them.
- ADR-005's credential bullet, which says prod projects point to a shared prod
  Supabase instance, is corrected by this ADR: prod is per project. ADR-005's
  own decision — separate credential sets per environment, automated promotion
  — still stands.
- Each project gains one new secret: the `<proj>_staging` role password, held
  in that project's Railway staging environment.
- **Open, and not resolvable from this repository**: prod connections are per
  project against databases whose tables are in `public`, so the pooler's
  handling of `options` is not load-bearing there today. Whether any prod
  connection string still carries `options=-c search_path` can only be checked
  in Railway.

## Alternatives considered

- **`options=-c search_path` in the connection URL** (what `011` and `014`–`017`
  document): rejected. The Supavisor pooler discards it, so the connection
  silently resolves against the default search path. This is the defect that
  produced this ADR.
- **`ALTER ROLE ... SET search_path` on the existing `{project}_app` role**:
  rejected. A `NOLOGIN` role cannot be the authenticating user, so its
  `search_path` default never applies to the app's session.
- **Schema named `<proj>`, role named `<proj>_staging`**: rejected. With
  mismatched names the default `"$user", public` path resolves nothing, and the
  search path has to be carried somewhere again. Matching the names is exactly
  what removes the URL parameter.
- **Transaction-mode pooler (port 6543)**: rejected. Alembic's DDL needs session
  mode.
- **A per-project staging database, mirroring prod's isolation**: rejected. That
  is the per-instance cost ADR-006 set out to remove, and one shared staging
  database with schema isolation already bounds the blast radius.
