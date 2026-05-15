---
created: '2026-05-15'
github_issue: null
id: '012'
status: idea
title: Migrate Annie to consolidated DB (prod + staging schemas)
updated: '2026-05-15'
---

## Why

Annie currently runs its own Supabase instances (prod + staging), incurring separate DB costs. Migrating to the consolidated DB eliminates those costs while maintaining full isolation via schema-level Postgres roles.

## What

Take an extra manual backup of Annie's prod and staging Supabase DBs before touching anything. Create annie schema and dedicated Postgres role in the default (prod) DB and staging DB. Migrate all data one-shot. Update Annie's connection strings to point to the new schemas. Validate data integrity before decommissioning old DBs. Do not decommission until validation passes. Depends on 010 and 011.

## Issues

_None yet._