---
created: '2026-10-07'
github_issue: null
id: '018'
status: draft
title: The factory works whatever Lachesis says is next, on the account Lachesis names
updated: '2026-10-07'
---

## Why

The factory stops whenever one Claude account runs out, even when another account has allowance left. In the week of 2026-10-07 the factory account was spent by Tuesday while main still had 25% usable, and nothing ran until Friday's reset. It also ignores Lachesis's backlog: it picks work by its own labels and holds whole classes of work for the author (factory-gap, requirements-gap, human-needed, manual-review, question, archon:skipped). The factory's own repairs therefore never run, about 50 requirement gaps sit idle, and Lachesis's sprint plan describes work that cannot happen. That breaks the founding rule: the author is never on the critical path.

## What

While any registered Claude account has allowance Lachesis lets the factory use, the factory keeps working: each run goes to the account Lachesis names for it, and only a run with no usable account waits. The factory takes its work from Lachesis, in Lachesis's order. Every issue Lachesis offers is worked unless a recorded question blocks it, and no issue waits for the author because of a label. What the factory does is visible in Lachesis: usage per account, and a handoff note on each issue it stops working on.

## Issues

_None yet._