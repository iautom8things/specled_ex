---
id: specled.decision.resolution_path_provenance
status: accepted
date: 2026-08-11
change_type: narrows-scope
affects:
  - specled.binding
  - specled.api_boundary
reverses_what: >-
  A committed api_boundary hash was previously comparable with any freshly
  resolved hash for the same binding, regardless of which resolution path
  produced either one. Comparison is narrowed to same-path pairs: a cross-path
  encounter emits `branch_guard_resolution_path_divergence` rather than
  `branch_guard_realization_drift`, and unlabeled legacy entries compare under
  same-path legacy semantics.
---

# Hashes Carry Resolution-Path Provenance; Cross-Path Comparison Is Divergence, Not Drift

## Context

`Binding.resolve/2` is BEAM-first with a source-AST fallback
(`specled.decision.beam_first_binding_resolution`). The two paths canonicalize
to structurally different envelopes: BEAM debug_info yields a 4-tuple over all
clauses (`{:__spec_head__, fun, arity, normalized_clauses}`), the source
fallback a 5-tuple over the first parsed def clause
(`{:__spec_head__, fun, arity, arg_pattern, defaults}`). The same unchanged
function therefore hashes to two different values depending on whether
`Code.ensure_loaded/1` succeeded when the check ran (specled_-n5q.1).

The observed harm is not wrong verdicts on compiled trees — CI and adopter
make targets compile before checking, so the BEAM path wins in practice. The
harm is fabricated evidence: an uncompiled tree (cold `_build`, wrong
`MIX_ENV` build dir) sends resolution down the source fallback and reports
plausible-looking `branch_guard_realization_drift` for code nobody changed.
During an adopter review this very mechanism most likely produced a
reviewer's wrong conclusion that `MIX_ENV` owned that adopter's baseline
churn.

Making the two paths hash identically was considered and rejected: source
canonicalization would need to reproduce Elixir's def unpacking (default
expansion per arity, clause grouping, guard capture) to converge on BEAM
clause content — a re-implementation of compiler behavior, not a hashing
tweak. The source path additionally cannot even locate default-arity heads
(`def f(a, b \\ 1)` under a `f/1` binding), so parity is unreachable without
compiling.

## Decision

1. Committed api_boundary hash entries record the resolution path that
   produced them: `"resolved_via": "beam" | "source"`. Bare-module entries
   are `beam` by definition (loadability is a precondition).
2. The detector compares hashes only same-path. An entry without
   `resolved_via` (written before this decision) compares under legacy
   drift semantics — treated as same-path. "Assume beam" was the first
   design and was empirically refuted by this project's own gate run:
   bindings on PRIVATE functions always resolve via source
   (`function_exported?/3` is false, so beam extraction is never tried),
   so their unlabeled baselines were source-written and the assumption
   fabricated divergence warnings across the corpus. The writer ran the
   same resolver against the same declaration, so same-path is the
   correct default; the residual blind spot — a beam-written unlabeled
   baseline met by a cold-tree source resolution — is exactly today's
   fabricated-drift bug, and it closes at the first labeling refresh.
3. A cross-path encounter emits `branch_guard_resolution_path_divergence`
   (default severity: warning) naming both paths, instead of drift. The
   message names compiling as the likely remedy, and entry deletion as the
   accepted mechanism for a permanent path change. The new finding code is
   justified against `specled.decision.finding_code_budget` in that ADR's
   2026-08-11 amendment: it re-classifies a formerly-wrong drift emission
   rather than adding a new emission surface.
4. Divergence blocks baseline refresh in both branches, including
   `--accept-drift`: refreshing under divergence would overwrite beam-hashed
   baselines with structurally different source hashes from an uncompiled
   tree. Diverged `(subject, mfa)` pairs are excluded from clean-binding
   attestations.
5. No `hasher_version` bump: same-path hashes are byte-identical to before;
   `resolved_via` is additive entry metadata. A hasher-version rehash drops
   the label (the rehash callback returns only a hash); the entry re-labels
   on its next write and is treated as legacy meanwhile.

## Consequences

- A cold-tree run against a LABELED entry reports an explicit, attributable
  warning instead of fabricated drift, and cannot silently poison the
  committed baseline. The qualifier matters: per Decision point 2, an
  unlabeled legacy entry still compares under legacy semantics, so a
  cold-tree run met by an unlabeled baseline can still report drift for
  code nobody changed. That case is time-boxed to the first labeling
  refresh, not eliminated by this ADR.
- The source path's first-clause-only weakening becomes harmless for
  verdicts: source hashes only ever compare against source-labeled entries.
- Test-harness fidelity: Mix's test task disables `:debug_info` for runtime
  compilation, so every runtime-compiled fixture in this suite had been
  resolving through the source fallback — the suite was not exercising the
  path production uses, and `@compile {:no_debug_info, true}` on the NoDebug
  fixture was a no-op that only appeared to work because of the same env
  default. Fixtures now compile through
  `SpecLedEx.FixtureCompiler.compile_to_path_with_debug_info/2`; the
  stripped-debug degrade fixture deliberately compiles without it.
