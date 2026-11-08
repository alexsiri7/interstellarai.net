# Rulings

This project's rulings: answers its owner has already given. They replace the SDLC
pack's default rulings document (`.shared/policy/rulings.md` in the workflow pack)
whole. Plan and review read them before they stop for a person, and a question one of
them answers is settled.

- **A change lands here.** When a change could land in this repository (a
  project-local override under `.archon/`, a script under `ops/`) or in a shared
  repository such as the SDLC pack in alexsiri7/Archon, it lands here and the shared
  repository stays unchanged. It is not a person's call. Rests on the owner's decision
  on #259 (2026-11-07) and on #270.
- **A part blocked on another issue is split off, not asked about.** Triage splits an
  item whose part waits on an open issue ([`triage.md`](triage.md), "Scope and
  ownership calls are the factory's"). A later node that finds such a part names it
  and stops without calling it a person's call; settle runs the item again and its
  triage splits it. Rests on #270.
