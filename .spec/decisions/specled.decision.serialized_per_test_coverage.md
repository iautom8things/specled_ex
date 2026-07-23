---
id: specled.decision.serialized_per_test_coverage
status: accepted
date: 2026-04-21
affects:
  - specled.coverage_capture
  - specled.triangulation
change_type: clarifies
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
  and accepts a `snapshot_fn` init option (see the specled_-155.4 amendment
  below for its arming and default-resolution rules).
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

## Amendment (specled_-155.4): arming seam + no fabrication

Red-team specled_-47j found that the formatter as originally shipped produced
garbage records under realistic use, for two compounding reasons:

1. **Bare wiring was live wiring.** Any `test_helper.exs` that added
   `SpecLedEx.Coverage.Formatter` to `:formatters` — the exact snippet
   `docs/adoption.md` told brownfield adopters to paste — activated real
   `:cover` capture immediately. There was no distinction between "the module
   is registered" and "a real `mix spec.cover.test` run is in progress."
2. **The production default was function-level, not line-level.**
   `:cover.analyse/1` (arity 1) defaults to `analyse(Module, coverage,
   function)` — MFA-shaped, call-count entries — not line-level ones. Rather
   than requesting `:line` explicitly, the original formatter's `snapshot_fn`
   default called the bare arity-1 form and then *fabricated* a `{file, 0}`
   line-hit record for every function-level entry it saw, regardless of
   whether that function ever ran. A third clause laundered any other
   unrecognized snapshot shape into `[]`, and an empty per-file grouping was
   padded with a placeholder record — so a decode failure and "nothing
   executed" were indistinguishable from real coverage on disk.

Decision:

- The formatter is inert by default. `init/1` is disarmed unless
  `Application.get_env(:specled_ex, :spec_cover_run)` is set; only `mix
  spec.cover.test` sets it. Disarmed, the formatter prints one stderr notice
  and no-ops every event — no artifact is ever written.
- `init/1`'s own argument is never trusted as a config source. ExUnit starts
  every formatter with its entire `:ex_unit` application environment as that
  argument (`ExUnit.configuration/0`), which is not caller intent and is an
  accidental smuggle path for unrelated config. Once armed, formatter config
  comes only from the `:specled_ex` arming value itself — `true` for
  production defaults, or an explicit keyword list (the test-only seam).
- `SpecLedEx.Coverage.init/2` no longer defaults `:snapshot_fn` or
  `:snapshot_target` — it raises `ArgumentError` if either is omitted. Silent
  defaulting is what let a formatter run for real without anyone deciding it
  should. `SpecLedEx.Coverage.Formatter` (the sole production caller) is the
  only place that supplies the explicit production defaults, and it requests
  `:cover.analyse(target, :coverage, :line)` — real line-level granularity —
  rather than the function-level arity-1 default.
- The formatter never fabricates a record for a snapshot entry it cannot
  honestly attribute to a source line. A function-level (MFA-shaped) entry,
  a snapshot with no line-level entries, and any unrecognized snapshot shape
  are each counted as a decode error and surfaced via one stderr notice per
  flush — never turned into a placeholder or a `{file, 0}` record.

### Consequences (amendment)

- Positive: a `.spec/_coverage/per_test.coverdata` artifact that exists is
  now honest — every record traces to a real, attributed line. Absence of a
  record is distinguishable from a decode failure (surfaced on stderr) and
  from "the run never happened" (the disarmed no-op).
- Positive: closes the exact vector `docs/adoption.md` walked adopters
  through; bare `test_helper.exs` wiring is now harmless without `mix
  spec.cover.test`.
- Negative: any external tooling or custom `snapshot_fn` written against the
  old function-level fallback or the old implicit `Coverage.init/2` defaults
  needs updating — both now require explicit configuration.
