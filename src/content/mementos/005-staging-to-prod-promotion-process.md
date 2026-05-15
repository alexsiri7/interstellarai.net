---
title: Staging to production promotion process
number: 5
status: accepted
date: 2026-05-15
---

## Context

The portfolio uses fully automated deployment: Archon picks up issues, drafts
PRs, CI validates them, and the pr-maintenance cron merges clean PRs to `main`.
From there, the CD pipeline deploys to staging and then to prod without human
intervention.

ADR-001 established the principle that every backend must pass a staging gate
before reaching prod, but left the promotion *process* implicit — scattered
across CI workflows, Railway config, and tribal knowledge. Three things need an
explicit, single-source reference: what qualifies a staging deploy for
promotion, who or what authorizes the promotion, and how credentials are
managed across environments.

## Decision

**Staging validation requirements** — what must pass before prod promotion:

- The staging deploy must succeed: Railway deploy exits 0 and the GitHub
  Deployments API status is `success`.
- Smoke and E2E tests run against the live staging URL (not mocks). If staging
  is unreachable, promotion blocks.
- Main-branch CI must be green at the exact commit being promoted.
- The `pipeline-health-cron` (ADR-002) serves as the detection layer: if a
  staging deploy fails or CI goes red, the cron fires a self-healing issue
  within 30 minutes.

**Approval authority** — who can promote to prod:

- Promotion is fully automated. There is no human approval step, consistent
  with the rationale in ADR-001.
- The staging test gate *is* the authorization mechanism — passing it is both
  necessary and sufficient.
- The `pr-maintenance-cron` drives merges to `main`; the CD pipeline handles
  staging deploy, test gate, and prod deploy.
- Archon-generated PRs follow the same gate. There is no bypass for automated
  PRs.

**Credential management** — how secrets differ across environments:

- Each environment (staging, prod) owns its own set of secrets. Credentials
  are never shared between environments.
- Connection strings: staging projects point to the staging Supabase instance;
  prod projects point to the prod Supabase instance (requirement 010).
- Secrets live in Railway environment variables, scoped per environment
  (staging env ≠ prod env). They are injected at deploy time by the platform.
- No `.env` files are committed to version control. Local development uses
  `.env.local`, which is gitignored.
- The `pipeline-health-cron` reads secrets from
  `~/.config/archon-cron/secrets.env` on the host machine (not committed).

## Consequences

- **Zero human toil on happy-path promotions**: when staging is green, prod
  ships automatically. No Slack threads, no approval clicks.
- **Broken staging blocks all promotions**: a failing staging environment
  halts the entire pipeline until fixed. This is intentional — the gate exists
  to prevent broken code from reaching users.
- **Credential isolation limits blast radius**: a misconfigured or leaked
  staging secret cannot corrupt prod data, because the two environments use
  entirely separate credential sets and database instances.

## Alternatives considered

- **Manual promotion approval** (e.g. a GitHub Actions environment gate
  requiring a reviewer click): rejected for the same reason as ADR-001 — it
  adds a human step that breaks on weekends, while traveling, and under load.
  The automated test gate provides equivalent confidence without the toil.
- **Shared staging/prod credentials with environment flags**: rejected. This
  defeats the isolation guarantee. A leaked staging secret would also be a
  prod secret, and a misconfigured flag could route staging traffic to prod
  data. Separate credential sets are worth the extra setup cost.
