---
created: '2026-05-15'
github_issue: 29
id: '015'
status: idea
title: Migrate Kindred to consolidated DB
updated: '2026-05-15'
---

## Why

Eliminate Kindred's standalone Supabase DB cost by migrating to the consolidated instance.

## What

Take an extra manual backup of Kindred's Supabase DB. Create kindred schema and dedicated Postgres role in the default (prod) DB and staging DB. Migrate all data one-shot. Update Kindred's connection strings. Validate data integrity before decommissioning old DB. Do not decommission until validation passes. Depends on 010 and 011.

## Issues

- #29 — Migrate Kindred to consolidated DB