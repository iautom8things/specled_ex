---
id: specled.decision.compiler_context_di
status: accepted
date: 2026-04-21
affects:
  - specled.compiler_context
  - specled.api_boundary
  - specled.implementation_tier
  - specled.expanded_behavior_tier
  - specled.use_tier
  - specled.triangulation
change_type: clarifies
---

# All Realization Orchestrators Accept `%SpecLedEx.Compiler.Context{}` Explicitly

## Context

Testability review 04b#1.1 flagged that orchestrators currently reach into
`Mix.env()`, `Mix.Project.config()`, and `_build/` paths internally. This makes
them unusable for fixture-based tests (the fixture has its own build path) and
fragile in production (implicit reads from outer project state can
contaminate fixture compiles when both run in the same process).

Review 04b#2.1 adds: tests must not depend on the outer project's `_build/`.
Review 04b#5.1 adds: the compile manifest format is the version-sensitive
canary — it wants to be read exactly once through a single seam.

The refinement introduces `%SpecLedEx.Compiler.Context{}` as the DI struct,
already validated as feasible via `Mix.Compilers.Elixir.read_manifest/1`
(stdlib API) and `Code.Tracer` (stdlib behaviour).

## Decision

- `SpecLedEx.Compiler.Context` is a struct with fields `manifest`,
  `xref_graph`, `tracer_table`, `compile_path`.
- Production wires it via `Context.load/1`, which takes explicit `app:`,
  `env:`, `build_path:` options. `load/1` does NOT consult `Mix.env/0` or
  `Mix.Project.config/0` internally.
- Every module under `SpecLedEx.Realization.*` and
  `SpecLedEx.CoverageTriangulation` whose public functions need compile
  inputs accepts a `%Context{}` as a positional argument.
- Tests construct a `%Context{}` with fixture-pointing fields. Production code
  paths call `Context.load/1` once at Mix-task entry.
- `grep -r 'Mix\.\(env\|Project.config\)' lib/specled_ex/realization/
  lib/specled_ex/coverage_triangulation.ex` returns zero hits after S2.

## Consequences

- Positive: orchestrators are pure-input / pure-output with respect to compile
  state. Unit-testable without spinning up Mix.
- Positive: fixture integration tests (scenario 1, 4, etc.) can load a
  fixture-pointing Context and run orchestrators against it without
  contaminating outer `_build/`.
- Positive: one documented seam for compile-manifest format drift. A minor
  Elixir bump that changes the manifest produces one failing integration
  test, not scattered behaviors.
- Negative: the public API of every orchestrator changes shape. S2 lands the
  change in one stage; no gradual migration is supported.
