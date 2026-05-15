---
created: '2026-05-15'
github_issue: 28
id: '014'
status: idea
title: Migrate FilmDuel to consolidated DB
updated: '2026-05-15'
---

## Why

Eliminate FilmDuel's standalone Supabase DB cost by migrating to the consolidated instance.

## What

Take an extra manual backup of FilmDuel's Supabase DB. Create filmduel schema and dedicated Postgres role in the default (prod) DB and staging DB. Migrate all data one-shot. Update FilmDuel's connection strings. Validate data integrity before decommissioning old DB. Do not decommission until validation passes. Depends on 010 and 011.

## Issues

- #28 — Migrate FilmDuel to consolidated DB