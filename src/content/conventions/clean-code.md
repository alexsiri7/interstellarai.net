---
title: Clean code
order: 1
summary: Principles for code humans and AI agents can keep reading. Small functions, honest names, one level of abstraction, and the discipline to leave duplication alone until it earns its abstraction.
updated: 2026-04-18
---

## Why this exists

Code is read far more often than it is written. In a portfolio where agents draft most PRs and humans review them, the cost of a confusing function is paid every time another agent tries to extend it. These principles are the shared baseline the PR review agent uses, and the vocabulary humans use to push back when the agent is wrong.

The goal is not purity. The goal is code that a tired human and a cold-start agent can both understand in one pass.

## Single Responsibility Principle

**Rule**: a class or function has one reason to change.

Describe what it does in one sentence. If you need `and` or `or`, you have two responsibilities fused together. A `UserService` that loads users, formats user profiles, and sends welcome emails has three reasons to change; the email templating team, the database team, and the profile UI team all edit the same file and step on each other.

The test is not "how many methods does it have" but "who is the customer". One module per customer.

## Single Level of Abstraction

**Rule**: a function mixes at most one level of abstraction.

Don't interleave business logic with I/O. Don't mix policy with mechanism. A function that decides *what* to charge a customer should not also know *how* to serialise JSON over HTTP to Stripe. If you read a function top-to-bottom and the reading speed changes — "high-level, high-level, oh now we're parsing a header" — you've mixed levels.

```
# mixed levels — bad
def checkout(cart):
    total = sum(item.price for item in cart.items)
    if cart.coupon:
        total *= (1 - cart.coupon.discount)
    resp = requests.post("https://api.stripe.com/charges",
                        json={"amount": int(total * 100)},
                        headers={"Authorization": f"Bearer {os.environ['STRIPE_KEY']}"})
    resp.raise_for_status()
    return resp.json()["id"]

# one level — good
def checkout(cart):
    total = price_after_discount(cart)
    return payments.charge(total, currency=cart.currency)
```

The rewritten `checkout` reads like a specification. The HTTP plumbing is in `payments.charge`, where it can be tested and swapped without touching checkout logic.

## Small functions

**Rule**: aim for functions that fit on a screen. Roughly 20 lines is a soft target.

This is not a religion. A 25-line function that reads top-to-bottom in one thought is fine. A 12-line function with four nested conditionals is not. The target exists because large functions almost always hide a missing abstraction — a loop body that wants to be its own function, a two-step algorithm pretending to be one step.

When you find yourself scrolling to see the end of a function, ask: "what would I call the middle of this?" If you can name it, extract it.

## Naming

**Rule**: nouns for things, verbs for actions, meaningful over clever.

Bad names force the reader to decode. `data`, `info`, `manager`, `util`, `helper`, `doStuff`, `process`, `handle` tell the reader nothing. Long, specific names beat short, vague ones every time: `days_since_last_login` beats `delta`. `cancel_pending_subscriptions` beats `cleanup`.

Banned without explicit justification: `Util`, `Utils`, `Manager`, `Helper`, `Service` as a generic suffix, `do*`, `handle*`, `process*`. If you reach for one of these you have not yet understood what the thing does. Understand it, then name it.

The exception is established idioms in the language or framework — `RequestHandler` in a web framework is fine; it's a term of art, not a dodge.

## DRY, with nuance

**Rule**: wait for the third instance before abstracting.

Two functions that look similar are not always the same thing. Two invoice-generation paths that share five lines of formatting may diverge next month when one gets VAT and the other gets sales tax. A premature abstraction couples them together; future edits now need to thread parameters through an abstraction nobody wanted.

The rule of three (Fowler): duplicate the code twice. On the third occurrence, extract. By then you know which parts are truly the same and which just happened to look alike.

Premature deduplication is worse than duplication, because duplication is visible and abstractions hide.

## Comments

**Rule**: comments explain the WHY, not the WHAT.

If a comment describes what the code does, the code is unclear — rewrite the code. `// increment counter` above `counter += 1` is noise. `// retry budget: the upstream rate-limits at 10/s and we need to stay under` is signal.

Good comments explain:

- non-obvious constraints (`// must be sorted — binary search below`),
- workarounds for bugs in other systems (`// Chrome 120 returns wrong mime-type for blob URLs`),
- security-critical invariants (`// this must run inside the auth check; do not move above`),
- references (`// algorithm from Knuth 4A §7.2.1.6, exercise 36`).

Comments that lie are worse than no comments. If the code changed and the comment didn't, delete the comment.

## Error handling

**Rule**: fail fast at boundaries, be specific about recovery, never swallow silently.

At the boundary of your code (HTTP handler, job consumer, CLI entry point), validate aggressively and reject bad input with a clear error. Inside your code, trust your types — don't pepper defensive checks through every function.

When you catch an exception, either handle it with intent (retry, fallback, transform into a domain error) or re-raise with added context. `except Exception: pass` and `catch (e) { console.log(e) }` are how systems corrupt state quietly. If you don't know what to do with an error, let it propagate.

Exceptions are for exceptional cases. Expected conditions — "user not found", "out of stock" — belong in return types, not throws.

## State and mutability

**Rule**: minimise mutable state. Prefer pure functions where possible.

Shared mutable state is the most common source of bugs in every non-trivial system. A function that takes inputs and returns outputs is testable, cacheable, and composes cleanly. A function that reads and writes a global, a singleton, or an argument by reference has a hidden contract with the whole program.

You cannot eliminate state — databases, files, and users exist. You can push it to the edges: a thin I/O shell around a pure core. The pure core is where bugs are cheap to find.

## References

- Robert C. Martin, *Clean Code* (2008). The Single Responsibility and Single Level of Abstraction rules come from here.
- John Ousterhout, *A Philosophy of Software Design* (2018). Chapter 2 ("The Nature of Complexity") and Chapter 4 ("Modules Should Be Deep") are the other half of this document; Ousterhout disagrees with Martin on function size, and both are worth reading.
- Martin Fowler, *Refactoring* (2nd ed., 2018). The rule of three, naming, and "extract function" are from here.
- Kent Beck, *Tidy First?* (2023). On when to refactor; short and correct.
- Dijkstra, *A Discipline of Programming* (1976). On state and invariants; old but still ahead of most new books.
