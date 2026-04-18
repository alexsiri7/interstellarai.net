---
title: Default deploy stack per project shape
number: 3
status: accepted
date: 2026-04-18
---

## Context

Projects fall into a small number of shapes, each with a different deploy
story:

- **Web backends + full-stack apps** — need a persistent host, a database, and
  staging
- **Mobile apps** — ship as store artifacts, not URLs
- **Static content** — marketing pages, docs, landing sites

Rather than decide hosting fresh for every new project, we pick defaults per
shape so a new project inherits a proven pipeline on day one.

## Decision

| Shape | Default stack | Build | Rationale |
|-------|---------------|-------|-----------|
| Web backend / full-stack | Railway, managed Postgres, staging + prod environments | GitHub Actions → Railway CLI deploy | Staging + managed DB are the two features that actually matter; Railway is the cheapest way to get both. |
| Mobile app | GitHub Actions builds signed artifact | Signed APK/AAB upload; store distribution is manual for now | Stores are the deploy target — no host needed. |
| Static site / docs | Cloudflare Pages or GitHub Pages | GitHub Actions auto-deploy on push to `main` | Free, fast, pairs cleanly with the DNS we already own. |

All web backends follow the staging-before-prod rule (ADR-001). All deploys
post to the GitHub Deployments API so the pipeline-health monitor (ADR-002) can
detect deploy regressions uniformly.

## Consequences

- A new project inherits deploy infrastructure by choosing its shape.
  Deviations require an ADR.
- Three platforms stay in play (Railway, GitHub Actions, Cloudflare/GitHub
  Pages). Acceptable — each justifies a distinct deploy shape.
- DNS convention: everything under `*.interstellarai.net`. Cloudflare holds the
  zone. Per-project subdomains point at whatever host their shape uses.

## Alternatives considered

- **One platform for everything**: no single host builds signed Android bundles
  *and* runs Postgres *and* serves static sites well. Rejected.
- **Self-hosted for web backends**: lower recurring cost, higher ops burden,
  single point of failure. Rejected — managed Postgres + staging on Railway is
  cheap enough that self-host isn't worth the toil.
- **Vercel for Next.js web apps**: possible, but splits the Postgres story
  across two vendors. Keeping app + DB on one platform is simpler.
