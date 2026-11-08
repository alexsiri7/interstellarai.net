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
- **Everything else goes to the owner.** Ask only when closing would change what the
  project should be (a spec decision: say that the spec would have to change), or when
  no reason above applies. Give the reason the item looks closable, if any, and what
  you recommend.
