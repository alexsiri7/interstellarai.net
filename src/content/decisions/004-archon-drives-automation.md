---
title: Archon is the automation engine across all projects
number: 4
status: accepted
date: 2026-04-18
projects: [reli, word-coach-annie, filmduel, cosmic-match, un-reminder]
---

## Context

Every project in the portfolio gets a steady stream of bugs, feature ideas,
dependency bumps, and test gaps. Doing this by hand across six projects would be
full-time work. We already built Archon — a YAML-driven AI coding harness — for
exactly this purpose.

## Decision

Archon drives all repeatable engineering work across the portfolio:

- **Issue → PR**: `archon-fix-github-issue` workflow converts an open issue into
  a drafted, CI-green, auto-merge-armed PR
- **Idea → PR**: `archon-idea-to-pr` turns a short prose spec into a scoped PR
- **Test coverage**: `archon-test-audit` finds under-tested modules and adds
  tests
- **Security**: `archon-security-audit` runs static analysis and files
  remediation PRs
- **PR maintenance**: `archon-pr-maintenance` rebases stale PRs and fixes their
  CI

Each project enables the workflows it wants via `.archon/` config. The automation
cron stack (ADR-002) fires these workflows on a schedule.

## Consequences

- **One tool to master, one tool to improve**: fixes in Archon benefit every
  project. The flip side — regressions in Archon break every project — is
  mitigated by Archon having its own CI and its own staging (the Archon PRs
  merged through the same pipeline it powers).
- **AI cost is nontrivial**: workflows consume Anthropic credits. Bounded by
  per-project throttling, per-SHA dedup in the auto-fix layer, and quota-aware
  backoff in the stall detector.
- **Archon itself is a project in the ecosystem**, which means it also gets
  drivers and maintenance pressure — Asiri contributes upstream patches (e.g.
  fix-github-issue CI bug, pr-maintenance cron PATH fix).

## How this interacts with other ADRs

- **ADR-001 (staging before prod)**: Archon doesn't bypass the staging gate —
  its PRs merge to `main` and then follow the same pipeline as human PRs.
- **ADR-002 (pipeline-health cron)**: Archon is also what gets fired by the
  health cron when something breaks. The cron is "archon of archons" — the
  supervisor that pokes archon when archon itself isn't making progress.
