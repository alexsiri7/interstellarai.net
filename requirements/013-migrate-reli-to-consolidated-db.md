---
created: '2026-05-15'
github_issue: 27
id: '013'
status: in-progress
title: Migrate Reli to consolidated DB
updated: '2026-05-15'
---

## Why

Eliminate Reli's standalone Supabase DB cost by migrating to the consolidated instance.

## What

Take an extra manual backup of Reli's Supabase DB. Create reli schema and dedicated Postgres role in the default (prod) DB and staging DB. Migrate all data one-shot. Update Reli's connection strings. Validate data integrity before decommissioning old DB. Do not decommission until validation passes. Depends on 010 and 011.

## Issues

- #27 — Migrate Reli to consolidated DB