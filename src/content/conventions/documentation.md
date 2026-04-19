---
title: Documentation
order: 2
summary: Every app has a README, every tech decision has an ADR, every external dependency is documented, and stale docs are deleted on sight. Reading the code is not documentation.
updated: 2026-04-18
---

## Why this exists

Documentation is a promise to your future self and to every agent or engineer who touches the repo after you. "Read the code to understand" is a failure mode dressed up as humility — it forces every reader to re-derive the mental model you already have. The portfolio ships too fast for that.

These rules are the minimum. The PR review agent enforces them; a PR that adds a new service without a README, or a new external dependency without a documented integration point, is flagged.

## Every app has a README

**Rule**: every repository has a `README.md` at the root that any reader can use to understand and run the project.

The README answers three questions in 2–3 short paragraphs:

1. **What does this app do?** One paragraph. Plain language, not marketing. "FilmDuel is a web app that ranks movies and TV shows using ELO duels. Users pick a winner between two titles and the system updates the ratings."
2. **Who is it for?** One or two sentences about the intended user and the kind of problem they bring. Without this, contributors build the wrong thing.
3. **How do I run it locally?** Concrete commands, from a clean clone: install dependencies, set environment variables, start the dev server, run the tests. If there are prerequisites (Postgres running, Node 20, a `.env.local` with specific keys), name them.

"See the docs" is not an answer. The README is the door; if the door is locked, nobody gets in.

## Major tech decisions are ADRs

**Rule**: any decision that shapes architecture, data, or the team's daily workflow is recorded as an Architecture Decision Record in MADR format.

ADRs live under `docs/adr/` in each repo, numbered sequentially, never renumbered. Each ADR has:

- **Context**: what forced the decision. Constraints, prior state, the problem in the reader's language.
- **Decision**: what we are doing, in the imperative. Not "we might consider", but "we will".
- **Alternatives considered**: the options we rejected and why. An ADR without rejected alternatives is a press release.
- **Consequences**: what this costs us. Trade-offs, new risks, things we now can't do.

ADRs are immutable. If the decision changes, write a new ADR that supersedes the old one, and mark the old one `superseded`. Nobody is embarrassed by an ADR that turned out wrong; they are embarrassed by decisions made without one.

The bar for "major" is lower than you think. If a future engineer would reasonably ask "why did we pick this?", write the ADR.

## Architecture overview in one file

**Rule**: the shape of the system is discoverable in a single file.

Either the README has an Architecture section, or there is a `docs/architecture.md`. It answers: what are the services, how do they talk to each other, where does the data live, what runs in CI, where does it deploy. A simple ASCII diagram beats a 40-page Confluence page nobody maintains.

"It's in the commit history" is not discoverable. "Ask the team" is not discoverable. If a new contributor (human or agent) cannot answer "what are the moving parts?" in ten minutes of reading, the overview is missing.

## External integrations are documented

**Rule**: every external service the app depends on has its own section explaining why it's there, what it does, and how to replace it.

For each of: auth provider, CDN, payment processor, email service, analytics, AI provider, managed database, feature-flag service — the docs name:

- **Why this service**: the concrete requirement it solves (not "best-in-class", actual reasons).
- **What it does for us**: which code paths call it, which data goes through it.
- **How to replace it**: the interface we depend on, the seams that make swapping possible, and the migration work required.

This matters for three reasons: vendors die, prices change, and data-residency requirements appear. A repo where Stripe is wired into forty files with no documentation is a repo held hostage to Stripe.

## Stale docs are worse than no docs

**Rule**: if a doc lies, delete it.

A wrong README sends every reader in the wrong direction with false confidence. A missing README makes them read the code, which is at least truthful. Delete the lie. Replace it when you have time.

This applies to:

- READMEs that reference commands that no longer work,
- architecture diagrams that show services we retired,
- comments that describe the previous implementation,
- ADRs that were superseded but never marked as such.

The PR review agent is empowered to flag a PR that changes behaviour without updating the corresponding docs, or to flag docs that contradict the code they describe. This is not pedantry; a document that claims to be current and isn't is a trap.

## References

- Michael Nygard, ["Documenting Architecture Decisions"](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) (2011). The original ADR post.
- [MADR: Markdown Architectural Decision Records](https://adr.github.io/madr/). The format we use.
- Daniele Procida, ["What nobody tells you about documentation"](https://documentation.divio.com/). The four-quadrant model (tutorials, how-to, reference, explanation) that shapes how to split up long-form docs.
- Will Larson, *An Elegant Puzzle* (2019), on why documentation decays and what to do about it.
