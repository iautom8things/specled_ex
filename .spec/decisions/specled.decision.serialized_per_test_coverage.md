---
id: specled.decision.serialized_per_test_coverage
status: accepted
date: 2026-04-21
affects:
  - specled.coverage_capture
  - specled.triangulation
---

# Per-Test Coverage Runs Are A Dedicated Serialized Pass, Not A Layer On `mix test --cover`

## Context

Red-team 04a#c2 verified that `:cover` has no per-pid surface: the tally is
process-global, so concurrent tests clobber each other's coverage in
async-test environments. Testability review 04b#3.1/3.3/6.1 compounds this:
without a `snapshot_fn` seam on the formatter, the formatter is untestable;
a named ETS table prevents parallel formatter instances in unit tests.

There are two honest paths: (a) build async-safe attribution (would require
replacing `:cover` entirely), or (b) accept that per-test attribution
requires serialization. Path (b) is cheap, sound, and compatible with the
existing `mix test --cover` cumulative mode, which users still rely on.

The spec explicitly wants per-test coverage as a Should-Have, not a Must. This
supports making it a second, opt-in pass rather than retrofitting `mix test
--cover` semantics.

## Decision

- `mix spec.cover.test` is a dedicated Mix task that wraps `mix test --cover`
  and forces `async: false` globally via
  `Application.put_env(:ex_unit, :async, false)` and `ExUnit.configure(async:
  false)` before any test module loads.
- The ExUnit formatter keys per-test state by `test_pid`, uses anonymous ETS,
  and accepts a `snapshot_fn` init option with default `&:cover.analyse/1`.
- The per-test artifact lives at `.spec/_coverage/per_test.coverdata`; only
  `mix spec.cover.test` writes it. `mix test --cover` continues unchanged.
- `SpecLedEx.Coverage.Store` is a separate module that reads the artifact and
  exposes a `build_records/1` helper so tests can author artifacts without
  instantiating a formatter.
- `SpecLedEx.IntegrationCase` ships `run_fixture_mix_test/2` for child-BEAM
  fixture runs so outer `:cover` state is never contaminated.

## Consequences

- Positive: attribution is sound; no race-condition flakes ship in v1.
- Positive: formatter and store are unit-testable without `:cover` running.
- Negative: users who want per-test attribution pay the async-false tax on
  their test suite duration during that run. Documented in AGENTS.md.
- Negative: two coverage paths (`mix test --cover` cumulative, `mix
  spec.cover.test` per-test) add cognitive overhead. Mitigated by clear
  docstrings and the separate task name.
