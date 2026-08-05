---
id: specled.decision.compile_connected_zero
status: accepted
date: 2026-08-05
affects:
  - specled.block_schema
  - specled.coverage_capture
change_type: clarifies
---

# The Compile-Connected Xref Graph Shall Stay at Zero Edges

## Context

A compile-time dependency on a module that has its own outgoing dependencies
("compile-connected" in `mix xref` terms) makes any change to the transitive
closure recompile the dependent. As of 0.11.0 the library had accumulated nine
such edges from three habits:

1. Module attributes evaluating remote calls at compile time
   (`@weakening_types Decision.weakening_types()`; every `Zoi.struct`
   definition calling `SpecLedEx.Schema.id()`).
2. Aliases referenced in module-body code executed at compile time
   (unused-alias suppressors like `_ = Meta`; the
   `setup {Module, :fun}` tuple in an `ExUnit.CaseTemplate` body). The
   suppressors also created two genuine compile-time cycles between
   `SpecLedEx.Schema` and its sub-schemas.

## Decision

`MIX_ENV=test mix xref graph --label compile-connected --fail-above 0` is a
merge gate, run as `make xref` locally and in CI. To keep it at zero:

- Values consumed at compile time live in **leaf modules** — modules with no
  dependency on any other project module (external deps like `Zoi` are fine,
  since `mix xref` tracks only project files). Current leaves:
  `SpecLedEx.Schema.Id`, `SpecLedEx.Schema.Verification`,
  `SpecLedEx.VerificationStrength`. A leaf carries a comment declaring the
  obligation.
- Where a compile-time evaluation is not needed, prefer a runtime call (the
  weakening-types lookup in `CrossField`) or a form that keeps the alias out
  of module-body code (the block-form `setup` in `SpecLedEx.Case`).

## Consequences

- Compile-time references to leaf modules are cheap and permitted; the gate
  only rejects edges to modules that themselves have dependencies.
- Adopter trees are unaffected: `mix xref` does not cross application
  boundaries, so documented adopter wiring such as
  `setup {SpecLedEx.Coverage, :per_test_boundary}` cannot trip an adopter's
  own gate.
- Reintroducing a compile-time remote call into a non-leaf module fails CI
  immediately rather than surfacing as slow incremental recompiles.
