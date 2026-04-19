---
title: Git and pull requests
order: 4
summary: Small PRs, imperative commit messages that explain the why, one logical change per branch, squash on merge, and nothing destructive on shared history.
updated: 2026-04-18
---

## Why this exists

The git history is documentation that writes itself, if you let it. A clean history lets any reader — human or agent — answer "why was this done?" by running `git log` and `git blame`. A messy history buries that answer under merge noise and WIP commits.

These conventions are the ones that hold up across every mainstream team. They're not unique; they are the baseline. The PR review agent enforces them so reviewers can spend their time on substance.

## Commit messages

**Rule**: imperative mood, sentence case, a short subject, a blank line, then a body that explains the why.

The subject line describes what this commit *does to the tree*, in the same voice git itself uses: `add retry budget to stripe client`, not `added` or `adds`. Soft cap of 50 characters so `git log --oneline` reads. Hard cap around 72.

The body explains the WHY. Not "I changed X to Y" — the diff already says that. The body says: what problem forced this change, what alternatives you considered, what future readers should know to avoid undoing it.

```
add retry budget to stripe client

Stripe rate-limits at 10 rps per account and our checkout burst
pushes through that window during flash sales. Before this change
we'd 429 on ~3% of charges and return a generic error to the user.

Retries are capped at 3 with exponential backoff, matching Stripe's
own recommendation. Beyond that we surface the rate-limit as a
domain error so the UI can show "please try again" rather than a
stack trace.
```

Body lines wrap around 72 characters so they render well in terminals and PR views. Tooling preserves the blank line between subject and body; don't fight it.

## One logical change per PR

**Rule**: a PR does one thing. If the title needs `and`, split.

A PR that "adds the retry budget and fixes the login-page typo and bumps the node version" cannot be reviewed carefully. Reviewers either rubber-stamp the combined diff or nitpick one part while the risky part slides through. If you catch yourself reaching for `and` in the title, open a second PR.

Split rules that usually hold:

- Refactors and behaviour changes go in separate PRs. Refactor first, behaviour second, so each is reviewable.
- Dependency bumps and feature work don't share a PR. A renovate-style bump is reviewed differently from a feature.
- "While I was in there" fixes belong in their own small PR, not smuggled in with a big one.

## Keep PRs small

**Rule**: target under 400 changed lines. Alarm over 800.

The research is unambiguous: review quality drops sharply above 400 lines. Reviewers either skim or rubber-stamp. At 800+ lines, bugs are roughly twice as likely to slip through, and reviewers stop leaving substantive comments. This matters more in a pipeline where an AI agent drafts the PR and a human is the last filter.

"Small" counts the changes that carry risk. A generated lockfile or a vendored directory doesn't count; a 600-line refactor across fifteen files does. If a PR is growing past 800 substantive lines, stop and split it — even if that means a stack of dependent PRs.

If a change genuinely cannot be split (large generated migration, single-commit vendor drop), say so in the PR description and point the reviewer at the parts that need human judgement.

## Branching and merging

**Rule**: feature branches off `main`, squash-merge on completion.

Squash-merging keeps `main` linear and makes every commit on `main` correspond to one reviewed PR. `git log --oneline main` reads like a changelog. `git revert` works cleanly because each commit is one logical change. `git bisect` finds regressions fast because each step is atomic.

Preserve history on release branches and long-lived integration branches — those need the full context of how they got there. Short-lived feature branches don't.

Never rebase a branch another person (or agent) is actively working on. Rebasing shared history destroys their work and there's no good recovery. If you need to incorporate `main`, merge it in, or ask the other author to pause first.

## Never force-push shared branches

**Rule**: `--force-with-lease` only on branches you own. Never on shared branches. Never, ever on `main` or release branches.

A force-push to a shared branch rewrites everyone else's history, orphans their in-flight work, and breaks CI pipelines that assumed a stable ref. `--force-with-lease` is slightly safer than `--force` because it refuses when the remote moved under you, but it's still a footgun on shared branches.

On your own feature branch, force-pushing to tidy commits before review is fine. After review starts, prefer additive commits; reviewers shouldn't have to re-review from scratch because you rebased.

## PR titles

**Rule**: conventional-commits style as a prefix, lightly applied.

```
feat: add retry budget to stripe client
fix: return 404 when user is deleted mid-request
chore: bump node to 20.11
docs: document the staging gate in readme
refactor: extract pricing rules into separate module
test: add integration test for coupon expiry
ci: cache npm install between jobs
```

These prefixes make the history skimmable and let the PR review agent route PRs to the right review depth — a `docs:` PR doesn't need the same scrutiny as a `feat:`. Don't be militant about the tag if a change spans two categories; pick the dominant one. Don't invent new prefixes.

The title after the prefix follows the same rules as a commit subject: imperative, sentence case, under ~60 characters.

## Safe operations only by default

**Rule**: treat these as off-limits unless a human explicitly approves: `git push --force`, `git reset --hard` on someone else's work, `git branch -D` on shared branches, skipping hooks (`--no-verify`), bypassing signing.

Hooks exist because the team agreed on a check. Skipping a hook because it's inconvenient silently moves the team's floor down. If a hook is wrong, fix the hook; don't bypass it.

Signing likewise. If commits aren't signing, fix the signing setup rather than turning it off.

## References

- Linus Torvalds / git project, ["SubmittingPatches"](https://git-scm.com/docs/SubmittingPatches). The source of the imperative-mood commit subject convention.
- Tim Pope, ["A Note About Git Commit Messages"](https://tbaggery.com/2008/04/19/a-note-about-git-commit-messages.html) (2008). The 50/72 character rule.
- Google, ["Modern Code Review: A Case Study at Google"](https://sback.it/publications/icse2018seip.pdf). Empirical basis for PR-size limits.
- Smart Bear, ["Best Kept Secrets of Peer Code Review"](https://smartbear.com/learn/code-review/). The 400-line defect-density study.
- [Conventional Commits](https://www.conventionalcommits.org/). The prefix style, used lightly.
