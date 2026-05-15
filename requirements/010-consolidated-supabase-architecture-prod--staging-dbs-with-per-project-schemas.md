---
created: '2026-05-15'
github_issue: null
id: '010'
status: idea
title: 'Consolidated Supabase architecture: prod + staging DBs with per-project schemas'
updated: '2026-05-15'
---

## Why

Each project currently has its own Supabase instance, incurring per-DB costs. Consolidating into two shared instances (prod + staging) reduces cost while maintaining isolation via Postgres schemas and per-project roles. Staging gives all projects a safe environment to test migrations before hitting prod.

## What

Two Supabase instances: "default" (prod, already exists) and "staging" (to be created). Each contains one Postgres schema per project: annie, reli, filmduel, kindred, lachesis. Each project gets a dedicated Postgres role with GRANT only on its own schema(s), so no project can accidentally access another's data. Staging mirrors prod schema structure exactly. All projects must migrate to this architecture.

## Issues

_None yet._