---
id: "004"
title: "Architecture Decision Records (Mementos)"
status: "done"
github_issue: 15
updated: 2026-05-12
---

## Why

Cross-project decisions (deploy targets, staging gates, automation tooling) need to be recorded with context, rationale, and consequences — not just implemented. ADRs are the artifact.

## What

Astro content collection at `src/content/mementos/`. Each ADR is a Markdown file with frontmatter (`title`, `number`, `status`, `date`, `projects`). `/mementos` index and `/mementos/<slug>` detail routes. Currently four ADRs: 001 (staging before prod), 002 (pipeline health auto-fix), 003 (per-project deploy targets), 004 (Archon drives automation).
