---
title: Staging gate required before production
number: 1
status: accepted
date: 2026-04-18
projects: [reli, word-coach-annie, filmduel]
---

## Context

The portfolio uses AI-driven automation to ship code: issues are picked up by
archon, PRs are generated, CI runs, and merges happen without human review on
the happy path. This compresses the feedback loop but also removes the human
gate that traditionally catches "looks fine, breaks in prod" regressions.

## Decision

Every backend service with a prod environment must have a staging environment
that the automation deploys to first, and a set of smoke/E2E tests that run
against staging. Prod deploys are gated on staging tests passing.

- Staging uses a separate database (not prod with a flag). Schema changes run
  against real data shape before they hit prod data.
- E2E tests target the staging URL, not a mock. If staging is down, prod doesn't
  ship.
- The staging→prod promotion is automated (no manual approval) so long as the
  gate passes — the gate is the control, not a human click.

## Consequences

- **More infra**: every project needs two Railway environments instead of one,
  plus a staging DB.
- **Slower shipping**: a commit takes ~5 more minutes to reach prod while
  staging deploys and tests run. Acceptable tradeoff.
- **Higher confidence**: regressions caught on staging never reach users, which
  is the whole point of automation-without-review.

## Status per project

| Project | Staging env | Pipeline | Notes |
|---------|:-:|:-:|-------|
| Word Coach Annie | ✅ | ✅ | Reference implementation |
| Reli | ⚠️ provisioned but unused | ⚠️ deploys to a legacy self-hosted target | Migration in progress |
| FilmDuel | ❌ | ❌ Railway native auto-deploy direct to prod | Adding gate tracked in filmduel#108 |

## Alternatives considered

- **Manual approval in GH Actions deploy workflow**: rejected. Adds a human step
  that breaks on weekends / while traveling. The point of automation is to keep
  shipping without a human in the loop.
- **Feature flags in prod instead of staging env**: rejected for backend-level
  regressions (DB migration errors, env-var misconfiguration) that flags don't
  catch. Flags stay for user-facing rollouts on top of the staging gate.
