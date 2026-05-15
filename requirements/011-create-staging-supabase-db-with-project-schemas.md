---
created: '2026-05-15'
github_issue: 25
id: '011'
status: idea
title: Create staging Supabase DB with project schemas
updated: '2026-05-15'
---

## Why

Staging DB must exist before any project can safely test their migration. Without it, migrations go straight to prod with no rehearsal.

## What

Create a new Supabase instance called "staging". Inside it, create one schema per project: annie, reli, filmduel, kindred, lachesis. Create a dedicated Postgres role per project scoped to its own schema only. This staging DB is the target environment for all project migration dry-runs before prod. Depends on 010.

## Issues

- #25 — Create staging Supabase DB with project schemas and roles