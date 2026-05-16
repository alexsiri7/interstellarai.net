---
title: 'Consolidated Supabase DB architecture: shared instances with per-project schemas'
number: 6
status: accepted
date: 2026-05-16
projects: [annie, reli, filmduel, kindred, lachesis]
---

## Context

Each project in the portfolio (annie, reli, filmduel, kindred, lachesis) had its
own Supabase instance, incurring per-database costs that scale linearly with
project count. Two shared Supabase instances already exist — one for prod
(the "default" project) and one for staging. The staging gate established in
ADR-001 requires every backend to pass staging before reaching prod, so staging
must mirror prod's schema structure exactly.

## Decision

Consolidate all five projects into two shared Supabase instances (prod and
staging) using per-project Postgres schemas and scoped roles:

- **Two instances**: prod and staging. No per-project instances.
- **One schema per project per instance**: each project owns a dedicated Postgres
  schema (e.g. `reli`, `filmduel`, `kindred`, `lachesis`, `annie`) rather than
  sharing the `public` schema.
- **Dedicated `{project}_app` role per project**: each project gets a `NOLOGIN`
  role (e.g. `reli_app`, `filmduel_app`) that is `GRANT`ed privileges only on
  its own schema. No role can access another project's tables.
- **Staging mirrors prod**: the staging instance contains the same schemas and
  role structure as prod, enabling safe pre-prod migration testing.
- **Migration SQL files live in `ops/db-migrations/`**: numbered sequentially
  from 014 onward (014-filmduel, 015-kindred, 016-lachesis, 017-reli). Each
  migration creates the project schema, the scoped role, grants permissions, and
  migrates any existing data from `public` into the new schema. Annie's schema
  isolation migration is tracked separately in issue #26.

## Consequences

- **Cost reduction**: N separate Supabase instances collapse to 2. Adding a new
  project adds a schema, not an instance.
- **Schema isolation**: each project's `{project}_app` role can only access its
  own schema. A misconfigured connection string or leaked credential cannot read
  or write another project's data.
- **Staging parity**: because staging mirrors prod schema structure, migration
  SQL can be validated against real schema shape before touching prod data.
- **Migration ordering matters**: schema isolation migrations must run after
  one-shot data migrations for projects that already had data in `public`. The
  numbered ordering (014–017) enforces this sequence.
- **Operational overhead**: migrations are manual SQL files run against each
  instance. There is no automated migration runner yet — this is acceptable for
  the current project count.

## Alternatives considered

- **Keep per-project Supabase instances**: rejected. Cost scales linearly with
  project count, and managing N sets of connection strings adds operational
  burden with no isolation benefit beyond what schema separation provides.
- **Shared `public` schema for all projects**: rejected. Without schema
  separation, any connection user can read any table. A single leaked credential
  exposes all project data.
- **Row-level security (RLS) in `public`**: rejected. Schema-level isolation is
  simpler and enforced at the Postgres role layer, not in application code. RLS
  policies are harder to audit and easier to misconfigure than schema grants.
