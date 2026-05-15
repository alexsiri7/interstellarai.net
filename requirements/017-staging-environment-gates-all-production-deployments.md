---
created: '2026-05-15'
github_issue: 31
id: '017'
status: idea
title: Staging environment gates all production deployments
updated: '2026-05-15'
---

## Why

Prevent untested changes from reaching prod across all projects. Any deployment, migration, or config change that goes straight to prod is a risk to real user data and service stability.

## What

Every project must have a staging deployment mirroring prod. No code, migration, or infrastructure change goes to prod without first being validated on staging. Staging DB schemas mirror prod schemas exactly. A documented staging → prod promotion process must exist and be followed.

## Issues

- #31 — Set up and verify Annie staging deployment
- #32 — Set up and verify Reli staging deployment
- #33 — Set up and verify FilmDuel staging deployment
- #34 — Set up and verify Kindred staging deployment
- #35 — Set up and verify Lachesis staging deployment
- #36 — Document staging → prod promotion process