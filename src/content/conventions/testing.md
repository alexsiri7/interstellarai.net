---
title: Testing
order: 3
summary: Integration tests over unit tests with heavy mocks. Test behaviour, not lines. Mock the edges, not code you own. Flaky tests are bugs, not weather.
updated: 2026-04-18
---

## Why this exists

Tests exist to let us change code without fear. A test suite that slows us down, lies about what the system does, or can't be trusted to fail for real reasons is worse than no suite at all. These conventions favour tests that catch real regressions over tests that decorate the coverage report.

## Integration tests over unit tests with heavy mocking

**Rule**: prefer tests that exercise real collaborators — real database, real HTTP to a local server, real filesystem in a temp directory — over unit tests that stub everything.

Mocks lie when reality changes. A unit test that mocks the database returns whatever you told it to return, which is exactly what the code-under-test expects, which is why the test passes. The same code against a real database finds the foreign-key violation, the off-by-one in the query, the implicit transaction that was missing. A fast integration test with a real Postgres in a container beats a bank of unit tests with stubs.

"Integration" here does not mean "end-to-end in prod". It means: real instances of things you control, at the smallest scope that exercises the contract. `testcontainers` for a database, a local HTTP server for an API client, a temp directory for a file-writer. Spin them up per-test-suite and tear them down; don't share state across tests.

This does not eliminate unit tests. It sets the default: integration first, unit where integration would be clumsy or slow.

## Unit test pure functions and complex logic

**Rule**: unit tests earn their keep on pure functions and on genuinely intricate branching logic.

A pricing calculator with twelve rules for VAT, coupons, and partial refunds wants exhaustive unit tests — one per rule, fast, pure, independent. A string formatter wants a table of input/output pairs. A parser wants a catalogue of malformed inputs.

Framework glue — controllers that wire a request to a service, Lambda handlers that parse an event and call one function — does not want unit tests. Those tests exercise mocks and indirection; they fail whenever you rename a field. Cover that layer with an integration test that actually hits the endpoint.

## Tests read as specifications

**Rule**: a test name tells the reader what the system does, in plain language.

`test_user_can_cancel_subscription_before_renewal` is a specification. `test_cancel_1` is noise. When a test fails, the name should tell a triaging reader what behaviour broke, without opening the test body.

Conventions that work:

- `it("returns 404 when the user does not exist")` — behaviour-driven style.
- `test_renewal_charges_full_price_when_coupon_has_expired` — snake case with the same structure.
- `Given_a_paid_user_When_cancelling_Then_subscription_ends_at_period_end` — Given/When/Then when a test covers several moving pieces.

Pick one style per repo and hold it. Don't mix.

## Coverage is a symptom, not a goal

**Rule**: track coverage as a signal. Don't target a number.

100% line coverage can be achieved by exercising every line without asserting anything. 60% line coverage can represent a rigorously-tested core with untested UI glue. The number alone tells you nothing.

What to look at instead:

- **Behaviour coverage**: do the important user journeys have a test? Can you delete a core feature and have a test fail?
- **Branch coverage on pure logic**: are the decision points in your pricing / auth / parsing code exercised with representative inputs?
- **Mutation testing** (e.g. Stryker, mutmut) when you really want to know the suite is honest: it changes an operator in the source and fails if your tests don't notice.

A PR that moves line coverage from 78% to 79% is not evidence of improvement. A PR that adds a test which would have caught the last production bug is.

## Mock the edges, not the code you own

**Rule**: mock things across a process or network boundary. Don't mock your own classes.

Good mocks: the Stripe client, the clock (`datetime.now`), the filesystem in tests where it would be slow, a third-party AI provider. These are edges — things you don't control, can't afford to hit, or that introduce flakiness.

Bad mocks: your own `UserRepository`, your own `InvoiceCalculator`, your own `EmailTemplateRenderer`. Mocking your own code couples the test to the current implementation. Any refactor that changes the internal wiring breaks the tests without any behaviour changing — the worst kind of test: expensive to maintain, no signal when it fails.

If a collaborator is hard to use in a test because of side effects, fix the design. Make it take a dependency you can substitute at the edge. Don't paper over the design with mocks.

## Flaky tests are bugs

**Rule**: a test that flakes twice is quarantined the same day and fixed that week. Never `@Ignore` and forget.

A flaky test trains the team to re-run CI until it passes, which trains the team to ignore real failures. The suite loses its signal and becomes a ritual.

When a test flakes:

1. Reproduce it. Run it 100 times locally, or in CI with a retry loop. If it flakes, the race is real.
2. Name the race. Async with no await? Time-of-day dependency? Order-dependent state? Test pollution from a previous test?
3. Fix it at the cause. Replace wall-clock time with an injectable clock. Reset the database between tests. Await the actual condition, not a `sleep(100)`.
4. If you cannot fix it today, delete it. A missing test is honest. A lying test is not.

Retry mechanisms (`--retries 3`) are an anaesthetic, not a cure. Use them only while you're actively fixing the flake, never as a permanent setting.

## References

- Martin Fowler, ["Mocks Aren't Stubs"](https://martinfowler.com/articles/mocksArentStubs.html) (2007, updated). The classic argument for why over-mocking lies.
- Kent Beck, *Test-Driven Development: By Example* (2002). Still the clearest short book on how tests drive design.
- Gerard Meszaros, *xUnit Test Patterns* (2007). The taxonomy for fakes, stubs, mocks, spies, and fixtures.
- Google Testing Blog, ["Flaky Tests at Google and How We Mitigate Them"](https://testing.googleblog.com/2016/05/flaky-tests-at-google-and-how-we.html). Data from a very large suite.
- Dave Farley, *Modern Software Engineering* (2021). On deterministic tests as a prerequisite for continuous delivery.
