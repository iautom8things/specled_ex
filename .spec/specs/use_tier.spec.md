# Use Tier + Macro Root-Cause Dedup

Tracks consumers of macro providers (`use` sites) and collapses fan-out drift
findings to a single root-cause message.

## Intent

A macro provider (module A with a `__using__/1`) can have dozens of consumers.
When A's provider changes, without dedup the guard emits N drift findings —
one per consumer — and the user gets flooded. Root-cause dedup inverts this:
one finding names A as the provider, lists the affected consumers with hash
prefixes, and suppresses the per-consumer drift. Consumers are recomputed from
the tracer on-demand (not persisted) so the consumer list is always current.

```spec-meta
id: specled.use_tier
kind: workflow
status: active
summary: use tier enumerates consumers via tracer; macro-provider root-cause dedup via Drift.dedupe/2 collapses N per-consumer findings to one per-provider finding with consumers_affected count and 8-char hash-prefix diff.
surface:
  - lib/specled_ex/realization/use.ex
  - lib/specled_ex/realization/drift.ex
  - test/specled_ex/realization/use_test.exs
  - test/specled_ex/realization/drift_test.exs
  - test/integration/scenario_macro_provider_drift_test.exs
```

## Requirements

```spec-requirements
- id: specled.use_tier.enumerate_consumers
  statement: >-
    SpecLedEx.Realization.Use.consumers_for/2 shall enumerate every
    module that contains a `use Provider` form by consulting the
    tracer side-manifest for `imported_macro` edges pointing at
    Provider. The consumer list shall not be persisted to state.json;
    it is recomputed each check.
  priority: must
  stability: evolving
- id: specled.use_tier.provider_hash_composes
  statement: >-
    The `use` tier hash for a subject declaring a provider shall be
    composed from the provider's `expanded_behavior` hash plus the
    sorted consumer module list. This makes the subject's use-tier hash
    drift when either the provider's expansion changes or the set of
    consumers changes.
  priority: must
  stability: evolving
- id: specled.use_tier.root_cause_dedupe
  statement: >-
    When a provider change produces drift in N consumers,
    Drift.dedupe/2 shall return one finding with the following
    shape:
    `%{code: :branch_guard_realization_drift, root_cause:
    %{provider: provider_mfa, tier: :use, hash_prefix_before: "abc12345",
    hash_prefix_after: "def67890", consumers_affected: N,
    consumers: [consumer_mod, ...]}}`. No per-consumer drift findings
    shall be emitted for drifts explained by this root cause.
  priority: must
  stability: evolving
- id: specled.use_tier.hash_prefix_length
  statement: >-
    The root_cause finding shall include 8-character hex prefixes of
    the before/after provider hashes. Shorter prefixes risk collision
    across the provider's history; longer ones are illegible.
  priority: should
  stability: evolving
- id: specled.use_tier.scenario_macro_provider_drift
  statement: >-
    Given a macro provider and 3+ consumers, a change that flips the
    provider's expanded body shall produce exactly one drift finding
    naming the provider, and zero drift findings naming the consumers.
    This is the gating criterion for scenario 4 of the spec.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: specled.use_tier.scenario.consumers_current_not_persisted
  given:
    - a Provider with two committed consumers C1, C2 in state.json's use-tier record
    - a branch that adds a new consumer C3
  when:
    - Use.consumers_for/2 is called for Provider
  then:
    - "the returned list is `[C1, C2, C3]`"
    - state.json's pre-existing list is ignored (not persisted)
  covers:
    - specled.use_tier.enumerate_consumers
- id: specled.use_tier.scenario.provider_drift_one_finding
  given:
    - "a Provider and three consumers C1, C2, C3"
    - "a committed provider expanded_behavior hash `abc12345...`"
    - "a change to Provider's __using__/1 producing new hash `def67890...`"
  when:
    - mix spec.check runs
  then:
    - "exactly one `branch_guard_realization_drift` finding names root_cause.provider = Provider"
    - "that finding's consumers_affected is 3"
    - "that finding's hash_prefix_before is `abc12345`"
    - "that finding's hash_prefix_after is `def67890`"
    - no drift finding names C1, C2, or C3
  covers:
    - specled.use_tier.provider_hash_composes
    - specled.use_tier.root_cause_dedupe
    - specled.use_tier.hash_prefix_length
    - specled.use_tier.scenario_macro_provider_drift
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/realization/use_test.exs
  execute: true
  covers:
    - specled.use_tier.enumerate_consumers
    - specled.use_tier.provider_hash_composes
- kind: command
  target: mix test test/specled_ex/realization/drift_test.exs
  execute: true
  covers:
    - specled.use_tier.root_cause_dedupe
    - specled.use_tier.hash_prefix_length
- kind: command
  target: mix test test/integration/scenario_macro_provider_drift_test.exs --include integration
  execute: true
  covers:
    - specled.use_tier.scenario_macro_provider_drift
```
