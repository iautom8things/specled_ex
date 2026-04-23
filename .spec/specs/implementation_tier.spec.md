# Implementation Tier + Subject-Boundary Closure

Second realization tier: follows call edges out from declared MFAs to their
transitive closure, bounded by subject ownership.

## Intent

`api_boundary` hashes only what the user named. `implementation` follows the
tracer's MFA edges to everything those MFAs call, hashes the closure, and stops
at subject boundaries (an MFA owned by a different subject contributes its
current hash as a reference, not its canonical AST). This keeps hashes
composable — when subject B's MFA changes, subject A's implementation hash
flips via the referenced hash, and drift findings dedupe around the root
cause.

```yaml spec-meta
id: specled.implementation_tier
kind: workflow
status: active
summary: Walks tracer edges from declared MFAs; hashes closure with subject-boundary stops + hash-ref composition (Cargo pattern); MFA ownership via binding map with surface + lexical tiebreak.
surface:
  - lib/specled_ex/realization/implementation.ex
  - lib/specled_ex/realization/closure.ex
  - test/specled_ex/realization/implementation_test.exs
  - test/specled_ex/realization/closure_test.exs
  - test/integration/scenario_refactor_stable_test.exs
realized_by:
  implementation:
    - "SpecLedEx.Realization.Implementation.run/4"
    - "SpecLedEx.Realization.Implementation.hash_for_subject/3"
    - "SpecLedEx.Realization.Closure.compute/2"
    - "SpecLedEx.Realization.Closure.subject_for_mfa/2"
```

## Requirements

```yaml spec-requirements
- id: specled.implementation_tier.closure_walks_tracer_edges
  statement: >-
    SpecLedEx.Realization.Closure.compute/2 shall walk MFA callee edges
    from the tracer side-manifest starting at the subject's declared
    `implementation` MFAs. The walk shall stop at (a) subject boundaries
    (an MFA owned by another subject), (b) MFAs outside the project's
    in-tree modules, and (c) already-visited MFAs (cycle guard).
  priority: must
  stability: evolving
- id: specled.implementation_tier.ownership_rule
  statement: >-
    Closure.subject_for_mfa/2 shall own `Mod.fun/arity` to subject S
    iff `Mod.fun/arity` appears in S's `realized_by.implementation`
    binding. Otherwise it falls back to the file-level mapping from
    `spec-meta.surface` (the source file containing the MFA's
    definition). If multiple subjects claim the same file via surface,
    the subject whose id sorts lexicographically smallest wins. If no
    subject owns the MFA, it is considered a shared helper (see below).
  priority: must
  stability: evolving
- id: specled.implementation_tier.shared_helper_accounting
  statement: >-
    An MFA that no subject owns (neither via `implementation` binding
    nor via `surface`) shall be inlined into every closure that reaches
    it — its canonical AST contributes to the hash of each caller's
    subject. This is the "shared-helper" rule and is unit-tested.
  priority: must
  stability: evolving
- id: specled.implementation_tier.hash_ref_composition
  statement: >-
    When the walk hits an MFA owned by another subject B, the hash
    input shall include the string `"subject:#{B.id}:hash:#{B.impl_hash}"`
    rather than B's canonical AST. When B's impl hash changes, A's
    hash changes via this reference; this is the composition-by-hash
    rule (Cargo pattern).
  priority: must
  stability: evolving
- id: specled.implementation_tier.scenario_refactor_stable
  statement: >-
    Given a subject with an implementation closure C, a cosmetic
    refactor inside C (rename locals, reflow whitespace, reorder
    functions with no semantic effect) shall not produce a
    `branch_guard_realization_drift` finding for that subject. This is
    the gating criterion for scenario 1 of the spec.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.implementation_tier.scenario.closure_walk_stops_at_boundary
  given:
    - subjects A with binding `A.foo/0` and B with binding `B.bar/0`
    - fixture where A.foo/0 calls B.bar/0 which calls B.helper/0
  when:
    - Closure.compute/2 is called for subject A
  then:
    - "the closure set for A is `{A.foo/0}`"
    - "the hash input for A includes a reference to `subject:B:hash:...` but not B.bar/0's canonical AST directly"
  covers:
    - specled.implementation_tier.closure_walks_tracer_edges
    - specled.implementation_tier.hash_ref_composition
- id: specled.implementation_tier.scenario.shared_helper_inlined
  given:
    - subject A with binding `A.foo/0`
    - a shared helper `Helpers.util/0` that no subject claims
    - A.foo/0 calls Helpers.util/0
  when:
    - Closure.compute/2 is called for subject A
  then:
    - "the closure set for A is `{A.foo/0, Helpers.util/0}`"
    - a change to Helpers.util/0's body changes A's hash
  covers:
    - specled.implementation_tier.shared_helper_accounting
- id: specled.implementation_tier.scenario.ownership_lexical_tiebreak
  given:
    - a file `lib/shared.ex` that defines `Shared.thing/0`
    - subjects `aaa` and `bbb` both listing `lib/shared.ex` in surface
    - neither names `Shared.thing/0` in its implementation binding
  when:
    - Closure.subject_for_mfa/2 is called with `{Shared, :thing, 0}`
  then:
    - the returned owner is `aaa`
  covers:
    - specled.implementation_tier.ownership_rule
- id: specled.implementation_tier.scenario.refactor_does_not_drift
  given:
    - a subject with an implementation closure of three MFAs
    - a committed implementation hash for that subject
    - a branch that renames local variables and reflows the bodies of all three MFAs
  when:
    - mix spec.check runs on the branch
  then:
    - no `branch_guard_realization_drift` finding is emitted for that subject
  covers:
    - specled.implementation_tier.scenario_refactor_stable
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/realization/closure_test.exs
  execute: true
  covers:
    - specled.implementation_tier.closure_walks_tracer_edges
    - specled.implementation_tier.ownership_rule
    - specled.implementation_tier.shared_helper_accounting
    - specled.implementation_tier.hash_ref_composition
- kind: command
  target: mix test test/specled_ex/realization/implementation_test.exs
  execute: true
  covers:
    - specled.implementation_tier.closure_walks_tracer_edges
- kind: command
  target: mix test test/integration/scenario_refactor_stable_test.exs --include integration
  execute: true
  covers:
    - specled.implementation_tier.scenario_refactor_stable
```
