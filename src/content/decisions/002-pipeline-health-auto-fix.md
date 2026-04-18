---
title: Pipeline-health cron for self-healing automation
number: 2
status: accepted
date: 2026-04-18
projects: [reli, word-coach-annie, filmduel, cosmic-match, un-reminder, beads]
---

## Context

The ecosystem relies on three crons to keep code flowing to prod:

- `issue-pickup-cron` — picks open GH issues and launches archon to draft fixes
- `pr-maintenance-cron` — merges clean PRs, rebases dirty ones, fixes failing CI

But these crons only work on happy-path inputs. Three failure modes exist where
nothing comes back to fix the pipeline itself:

1. **Main CI red** — something landed that broke `main`. Nothing picks this up
   because PR-maintenance only looks at PRs, not main.
2. **Prod deploy failed or lagging** — Railway webhook dropped, Actions workflow
   errored. The merge happened, the deploy didn't.
3. **Pipeline stalled** — no commits, no archon runs, no activity. Could be a
   quota limit, could be a systemic problem. Either way, nothing escalates.

## Decision

A fourth cron, `pipeline-health-cron`, runs every 30 minutes and detects these
meta-failures. When it finds one, it either files an issue tagged for archon
pickup (self-heal) or fires archon-assist directly (urgent bottleneck).

Specifically, each tick:

- **Main CI red** → file `archon:in-progress`-tagged issue, fire archon
  immediately on that issue, dedup by commit SHA via marker file
- **Prod deploy failed/lagging** → same pattern, using deploy SHA for dedup;
  reads signal from either the GH Actions deploy workflow or the GitHub
  deployments API (Railway posts here)
- **Zombie archon DB runs** (status=running, age >4h) → abandon
- **Disk pressure** >85% → ntfy
- **No progress** in last tick — if token-limit markers in logs, wait; else fire
  archon-assist diagnostic with 2h cooldown

## Consequences

- Self-healing covers three previously-silent failure modes.
- Zero cost when the pipeline is healthy — nothing fires.
- AI cost is bounded by the 2h diagnostic cooldown and per-SHA dedup.
- Adds one more thing to forget to deploy if the machine is reimaged — the cron
  needs to be re-installed. Mitigation: crontab lives in the memory reference
  file, re-install is documented.

## Alternatives considered

- **Nagios / Uptime Kuma / PagerDuty**: rejected. External monitoring tells you
  *that* something broke — the goal here is for the pipeline to fix *itself*
  without a human pager.
- **Put the auto-fix inside each project's CI**: rejected. CI only runs on push,
  so it can't detect "nothing happened for 30 minutes." Needs to be out-of-band.
