# Triage policy

The factory's triage policy for this project. It replaces the SDLC pack's default
(`.shared/policy/triage.md` in the workflow pack) whole. Owner decision of 2026-11-08
(interstellarai.net #259): the factory may close any item when it can say why.

- **Scope.** Judge whether an item is in scope against this repository's own
  documents: [`README.md`](../../../README.md), [`ops/cron/README.md`](../../../ops/cron/README.md)
  and [`requirements/`](../../../requirements). When none of them settles it, say so
  rather than invent its scope.
- **Closing without a person.** An item may be closed without the owner whenever the
  verdict can give the reason and the evidence for it:
  - it duplicates an open issue (name it), or a merged change already delivered its
    outcome (name the change);
  - it is an alert whose condition is false now (say what was checked and when);
  - it is a false positive or a duplicate of a closed issue, or a closed issue
    superseded it: name that closed issue by `#N` as the precedent;
  - the owner already decided in the thread: say that the owner decided, and quote the
    owner's own comment (not one the factory posted);
  - the spec already decides it: cite the spec file and line (`path:line`);
  - it is feedback that describes no defect: say so, and thank the sender.
  The pack's `NO_ACTION` closure can only carry the first two. For the others, declare
  `BLOCKED` with `blocked_reason` stating the reason and the evidence in the words
  above; `ops/cron/lib/settle-ship-outcome.sh` checks the evidence on GitHub, closes
  the item with that reason in its comment and labels it `factory-closed`, so the
  owner can read the closures and reopen any that are wrong.
- **Scope and ownership calls are the factory's (#270).** Never ask the owner where
  a change lands or whether to split an item:
  - *Land it here.* When the outcome can be delivered by a change in this repository
    (a project-local override under `.archon/`, a script under `ops/`) and could also
    land in a shared repository the run has not checked out (the SDLC pack in
    alexsiri7/Archon, another project), route it as work for this repository and say
    so in the assessment. Never `BLOCKED` on where to land. `BLOCKED` on another
    repository only when nothing here can deliver the outcome, naming its issue as
    `owner/repo#N`. (Owner's comment on #259, 2026-11-07 — the same decision the
    opening paragraph cites by #259's 2026-11-08 close date.)
  - *Split off a blocked part.* When an item bundles an outcome deliverable now with
    one that waits on an open issue in this repository, declare `BLOCKED` with
    `blocked_reason` exactly
    `a split: this issue keeps "<part delivered now>"; "<part that waits>" waits on #<N>`,
    each part one sentence with no double quotes inside it.
    `ops/cron/lib/settle-ship-outcome.sh` files the waiting part as a new issue
    blocked on #N, comments the split here and runs this item again. When the whole
    item waits on the issue, declare `BLOCKED` on it as before.
  - *The factory's own records are direction.* A comment headed
    `Scope (factory split, <date>)` is a split made under this rule: judge the item as
    scoped to what it keeps, as for an owner's dated scope section. A comment headed
    `Decision (factory, <date>): land it here` settles where the change lands.
- **Everything else goes to the owner.** Ask only when closing would change what the
  project should be (a spec decision: say that the spec would have to change), or when
  no reason above applies and no rule above decides it. Give the reason the item looks
  closable, if any, and what you recommend.
