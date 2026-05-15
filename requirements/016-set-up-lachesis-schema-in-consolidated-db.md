---
created: '2026-05-15'
github_issue: 30
id: '016'
status: idea
title: Set up Lachesis schema in consolidated DB
updated: '2026-05-15'
---

## Why

Lachesis is already on the default DB but lacks the schema isolation that protects it from other projects and vice versa. Needs to be brought in line with the consolidated architecture.

## What

Lachesis is already using the default DB but without a proper schema or dedicated Postgres role. Create a lachesis schema, move existing tables into it, create a dedicated role scoped to that schema only, and mirror the schema in the staging DB. No data migration needed — just schema isolation. Depends on 010 and 011.

## Issues

- #30 — Set up Lachesis schema isolation in consolidated DB