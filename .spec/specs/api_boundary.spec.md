# Api-Boundary Tier

First realization tier: hashes public-surface function heads and arg shapes,
emits drift and dangling findings.

## Intent

`api_boundary` is the cheapest realization tier: it hashes the function head
(name, arity, arg pattern shape, default-arg literals) of every MFA named by
a subject's binding, and compares against the previously committed hash. It is
the first tier users opt into because it catches surface-level drift cheaply
and without any compiled metadata. S2 ships this tier only; subsequent tiers
(implementation, expanded_behavior, use, typespecs) land in later slices.

```yaml spec-meta
id: specled.api_boundary
kind: workflow
status: active
summary: Hashes function heads + arg shapes per binding, emits `branch_guard_realization_drift` and `branch_guard_dangling_binding` findings, deduplicated via Drift.
surface:
  - lib/specled_ex/realization/api_boundary.ex
  - lib/specled_ex/realization/drift.ex
  - lib/mix/tasks/spec.suggest_binding.ex
  - lib/mix/tasks/spec.check.ex
  - test/specled_ex/realization/api_boundary_test.exs
  - test/specled_ex/realization/drift_test.exs
  - test/mix/tasks/spec_suggest_binding_test.exs
realized_by:
  api_boundary:
    - "SpecLedEx.Realization.ApiBoundary.hash/2"
    - "SpecLedEx.Realization.ApiBoundary.run/1"
    - "SpecLedEx.Realization.Drift.dedupe/2"
    - "Mix.Tasks.Spec.Check"
    - "Mix.Tasks.Spec.SuggestBinding"
decisions:
  - specled.decision.finding_code_budget
```

## Requirements

```yaml spec-requirements
- id: specled.api_boundary.hash_function_head
  statement: >-
    SpecLedEx.Realization.ApiBoundary.hash/2 shall produce a hash that
    is stable under formatting changes, variable renames, and line-
    number shifts in the function body, but changes when the function's
    arity, arg pattern shape, or literal default arguments change. A
    `:non_literal_default` rule shall be applied uniformly to function-
    head defaults (not just defstruct): non-literal defaults do not
    change the hash. This weakening shall be documented in the module.
  priority: must
  stability: evolving
- id: specled.api_boundary.drift_finding_emitted
  statement: >-
    When a resolved MFA's current hash differs from its committed hash,
    `mix spec.check` shall emit a `branch_guard_realization_drift`
    finding naming the subject id, requirement id (if requirement-level
    binding), tier (`api_boundary`), and the MFA.
  priority: must
  stability: evolving
- id: specled.api_boundary.dangling_finding_emitted
  statement: >-
    When Binding.resolve/2 returns `{:error, :not_found}` for any
    declared MFA in the api_boundary tier, `mix spec.check` shall emit
    a `branch_guard_dangling_binding` finding naming the subject id,
    tier, declared MFA, and a short remediation message that is
    copy-pastable into an agent prompt (MFA, tier, subject id all
    included verbatim).
  priority: must
  stability: evolving
- id: specled.api_boundary.drift_dedupe_narrow
  statement: >-
    SpecLedEx.Realization.Drift.dedupe/2 shall export exactly one
    function and shall be hard-capped at 150 LOC including moduledoc.
    It shall accept an explicit list of deltas plus a dependency
    predicate and return a deduplicated list. It shall not expose an
    extension API; future tiers compose it, they do not extend it.
  priority: must
  stability: evolving
- id: specled.api_boundary.dedupe_cyclic_tiebreak
  statement: >-
    When dedupe/2 encounters a connected component of subjects that
    does not form a DAG (cyclic provider relationships), it shall
    pick the subject whose id sorts lexicographically smallest as the
    root_cause provider. This tiebreak is deterministic and
    test-gated via a cyclic fixture.
  priority: must
  stability: evolving
- id: specled.api_boundary.suggest_binding_proposal_only
  statement: >-
    mix spec.suggest_binding shall print proposed `realized_by:` blocks
    for subjects with no binding and exit non-zero only if invoked with
    `--fail-on-missing`. It shall NOT accept a `--write` flag in v1 —
    agents apply proposals via their own editing tools.
  priority: must
  stability: evolving
- id: specled.api_boundary.umbrella_graceful_degrade
  statement: >-
    When `Mix.Project.umbrella?/0` returns true, ApiBoundary.run/1
    shall emit a single `detector_unavailable` finding with reason
    `:umbrella_unsupported` and skip without raising. v1 does not
    support umbrella apps; v1.1 will.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.api_boundary.scenario.refactor_whitespace_stable
  given:
    - "a subject with binding `realized_by.api_boundary: [\"Foo.bar/1\"]`"
    - a committed hash in `.spec/state.json` for that MFA
    - a change that adds whitespace to the function body but not the arity or arg pattern
  when:
    - mix spec.check runs on the branch
  then:
    - no `branch_guard_realization_drift` finding is emitted for `Foo.bar/1`
  covers:
    - specled.api_boundary.hash_function_head
- id: specled.api_boundary.scenario.arity_change_drifts
  given:
    - the same subject binding
    - a change that adds a new positional argument to `Foo.bar/1`, making it `Foo.bar/2`
  when:
    - mix spec.check runs
  then:
    - a `branch_guard_dangling_binding` finding references `Foo.bar/1` (no longer defined)
  covers:
    - specled.api_boundary.dangling_finding_emitted
- id: specled.api_boundary.scenario.drift_finding_on_arg_pattern_change
  given:
    - "a binding `\"Foo.bar/1\"` with committed hash"
    - "a change that replaces the arg pattern from `%{key: val}` to `%{key: val, other: _}`"
  when:
    - mix spec.check runs
  then:
    - a `branch_guard_realization_drift` finding references `Foo.bar/1`
  covers:
    - specled.api_boundary.drift_finding_emitted
- id: specled.api_boundary.scenario.cyclic_dedupe_tiebreak_stable
  given:
    - subjects `aaa.foo`, `bbb.bar`, `ccc.baz` whose bindings form a cycle at the dependency level
    - all three present identical deltas
  when:
    - Drift.dedupe/2 is called with a dependency predicate that models the cycle
  then:
    - the returned list names `aaa.foo` as root_cause provider
    - the choice is stable across runs
  covers:
    - specled.api_boundary.dedupe_cyclic_tiebreak
- id: specled.api_boundary.scenario.suggest_binding_prints_proposal
  given:
    - "a subject with no `realized_by` field and one `surface:` entry"
  when:
    - mix spec.suggest_binding runs
  then:
    - "stdout prints a YAML-form `realized_by:` block for that subject"
    - the task exits 0 without writing any files
  covers:
    - specled.api_boundary.suggest_binding_proposal_only
- id: specled.api_boundary.scenario.umbrella_skips_gracefully
  given:
    - a project where Mix.Project.umbrella?/0 returns true
  when:
    - mix spec.check runs with api_boundary enabled
  then:
    - "a single `detector_unavailable` finding names reason `:umbrella_unsupported`"
    - no crash occurs; exit status respects severity config
  covers:
    - specled.api_boundary.umbrella_graceful_degrade
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.api_boundary.hash_function_head
    - specled.api_boundary.drift_finding_emitted
    - specled.api_boundary.dangling_finding_emitted
    - specled.api_boundary.umbrella_graceful_degrade
- kind: tagged_tests
  execute: true
  covers:
    - specled.api_boundary.drift_dedupe_narrow
    - specled.api_boundary.dedupe_cyclic_tiebreak
- kind: tagged_tests
  execute: true
  covers:
    - specled.api_boundary.suggest_binding_proposal_only
```
