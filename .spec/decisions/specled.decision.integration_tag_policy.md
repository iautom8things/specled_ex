---
id: specled.decision.integration_tag_policy
status: accepted
date: 2026-04-21
affects:
  - specled.coverage_capture
  - specled.compiler_context
  - specled.implementation_tier
  - specled.expanded_behavior_tier
  - specled.use_tier
  - specled.triangulation
change_type: clarifies
---

# `:integration` Tag Is Excluded From Local `mix test`; CI Opts In

## Context

Testability review 04b#10.1 recommended: fixture-compile integration tests
(scenarios 1, 4, etc., plus manifest-format canaries) must exist and run on
every CI push, but local `mix test` should stay fast — a developer running
`mix test` repeatedly should not pay ~30-40 seconds for fixture compiles on
every round-trip. The `:integration` ExUnit tag is the standard solution;
the choice is where the default lives.

User review (2026-04-21, question 2) confirmed the refiner's recommendation:
exclude locally, include in CI.

## Decision

- `test_helper.exs` calls `ExUnit.start(exclude: [:integration])`.
- Fixture-compile tests under `test/integration/**/*_test.exs` carry
  `@moduletag :integration`.
- CI invokes `mix test --include integration` on push.
- Project `AGENTS.md` documents: running a specific integration test
  locally is done via `mix test <path> --include integration` or via
  `SpecLedEx.IntegrationCase` helpers that bypass the tag.
- The pattern applies equally to `:uses_cover` (always paired with `async:
  false`).

## Consequences

- Positive: local `mix test` stays under ~5 seconds for a clean run even as
  the integration suite grows.
- Positive: CI consistently executes every integration gate; fixture-compile
  scenarios are not "tested on demand."
- Negative: a local developer running `mix test` without flags does not
  catch integration regressions. Mitigated by `mix spec.check` (which
  downstream runs the full suite) and pre-push hooks when teams adopt them.
- Negative: a mistyped tag drops a test from both lanes. Single source of
  truth for the tag list in `AGENTS.md`.
