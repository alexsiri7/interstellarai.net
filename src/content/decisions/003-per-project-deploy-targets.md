---
title: Deploy target per project
number: 3
status: accepted
date: 2026-04-18
projects: [reli, word-coach-annie, filmduel, cosmic-match, un-reminder]
---

## Context

Projects in the portfolio have different deploy shapes:

- Web backends need a persistent, scalable host with a DB
- Mobile apps ship as store artifacts, not URLs
- Docs and marketing sites are static

Using one host for everything is wasteful. Using five different hosts is a
maintenance tax. This ADR fixes the mapping.

## Decision

| Project | Deploy target | Artifact | Rationale |
|---------|---------------|----------|-----------|
| Reli | Railway (migrating from legacy self-hosted target) | Docker image via Railway CLI | Needs staging DB, pgvector, long-running worker. Railway handles both. |
| Word Coach Annie | Railway | Next.js build | Same as Reli. Already reference impl. |
| FilmDuel | Railway | FastAPI + static frontend | Same as above. Staging gate pending (filmduel#108). |
| Cosmic Match | GitHub Actions → signed APK/AAB | Android bundle | Mobile — no host needed. Play Store is the deploy target. |
| Un-Reminder | GitHub Pages (privacy policy) + local install | Android APK | On-device AI, no backend. Pages only hosts the legal page. |
| interstellarai.net | Cloudflare Pages | Astro static site | Static marketing + docs; CF Pages is free, fast, and handles subdomain routing for per-project sites. |

All Railway-hosted services follow the staging-before-prod rule (ADR-001).

## Consequences

- **Four platforms to keep working**: Railway, GitHub Actions, CF Pages, Play
  Store. Acceptable; each is justified by a distinct deploy shape.
- **Subdomain convention**: everything under `*.interstellarai.net`. DNS lives
  in Cloudflare. Per-project subdomains point to their Railway URL.
- **Reli migration is the biggest open lift**: the workflow still deploys via
  SSH to a legacy self-hosted target. Tracked internally, blocked on human
  infra setup.

## Alternatives considered

- **All on Railway, including mobile**: Railway doesn't build signed Android
  bundles. Rejected.
- **All self-hosted**: lower ongoing cost, higher ops burden, single point of
  failure. Rejected — staging + HA on Railway is cheap enough that self-host
  isn't worth the toil.
- **Vercel instead of Railway for Next.js**: possible for WCA specifically, but
  splits the Postgres story. Keeping Postgres + app on Railway is simpler.
