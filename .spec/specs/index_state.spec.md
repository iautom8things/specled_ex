# Index And State

Index building and canonical state persistence for the Spec Led Development workspace.

## Intent

Define how the package discovers authored current-truth subjects and ADRs, then
persists a stable `.spec/state.json` artifact for later inspection and diffing.

```yaml spec-meta
id: specled.index_state
kind: workflow
status: active
summary: Builds the authored index and writes canonical derived state for the workspace.
surface:
  - lib/specled_ex.ex
  - lib/specled_ex/index.ex
  - lib/specled_ex/json.ex
realized_by:
  implementation:
    - "SpecLedEx.Index.build/2"
    - "SpecLedEx.write_state/4"
    - "SpecLedEx.Json.write!/2"
    - "SpecLedEx.Json.encode_to_iodata!/1"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.explicit_subject_ownership
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.dedicated_realization_baseline
```

## Requirements

```yaml spec-requirements
- id: specled.index.subject_and_decision_index
  statement: Index building shall discover authored subject specs and authored ADRs, detect the canonical workspace directories, and summarize indexed counts without treating `decisions/README.md` as an ADR.
  priority: must
  stability: stable
- id: specled.index.canonical_state_output
  statement: State writing shall normalize indexed entities, findings, verification data, and decisions into a canonical `.spec/state.json` artifact with stable ordering and no volatile persisted fields.
  priority: must
  stability: stable
- id: specled.index.json_resilience
  statement: JSON state helpers shall return an empty map for missing or invalid files, create parent directories on write, and skip rewriting identical canonical bytes.
  priority: must
  stability: stable
- id: specled.index.state_fully_derived
  statement: >-
    `.spec/state.json` shall be freely regenerable derived state: state
    writing shall not persist a realization baseline into state.json,
    and regenerating state.json shall not alter the committed
    `.spec/realization_hashes.json` baseline. Consumers may gitignore or
    regenerate state.json without defeating realization drift detection.
  priority: must
  stability: evolving
- id: specled.index.legacy_baseline_hoist
  statement: >-
    When the canonical `.spec/state.json` still carries a legacy embedded
    `realization` section and `.spec/realization_hashes.json` is absent,
    state writing shall hoist the embedded section into the dedicated
    baseline file before regenerating state.json, so the committed hashes
    survive the regeneration instead of being silently re-seeded from the
    current tree.
  priority: must
  stability: evolving
- id: specled.index.tag_data_conditional
  statement: Index building shall only scan test tags when enabled by configuration or caller options, and shall store the resulting tag map, parse errors, and effective tag configuration on the index under dedicated keys (`test_tags`, `test_tags_errors`, `test_tags_config`).
  priority: must
  stability: evolving
- id: specled.index.tag_data_absent_when_disabled
  statement: When test-tag scanning is disabled, the `test_tags`, `test_tags_errors`, and `test_tags_config` keys shall be absent or nil on the index so downstream verifiers do not emit tag findings.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.index.scenario.tag_scan_enabled_populates_keys
  given:
    - "a workspace whose `.spec/config.yml` enables test_tags"
    - "a test file containing an `@tag spec` annotation with id a.one"
  when:
    - Index.build/2 runs
  then:
    - the index has a non-nil `test_tags` map containing `a.one`
    - the index has a `test_tags_config` entry describing the effective config
  covers:
    - specled.index.tag_data_conditional
- id: specled.index.scenario.tag_scan_disabled_omits_keys
  given:
    - a workspace with test-tag scanning disabled
  when:
    - Index.build/2 runs
  then:
    - the index has `test_tags`, `test_tags_errors`, and `test_tags_config` absent or nil
  covers:
    - specled.index.tag_data_absent_when_disabled
- id: specled.index.scenario.regen_preserves_baseline
  given:
    - "a committed `.spec/realization_hashes.json` baseline"
  when:
    - write_state/4 regenerates `.spec/state.json`
  then:
    - the baseline file's bytes are unchanged
    - the regenerated state.json carries no `realization` key
  covers:
    - specled.index.state_fully_derived
- id: specled.index.scenario.conflict_ritual_preserves_baseline
  given:
    - "a committed `.spec/realization_hashes.json` baseline"
    - "a `.spec/state.json` discarded during a merge-conflict resolution (take either side)"
  when:
    - state.json is regenerated
  then:
    - HashStore.read/1 still returns the committed baseline (it is preserved, not recomputed)
  covers: []
- id: specled.index.scenario.legacy_hoist_on_regen
  given:
    - "a `.spec/state.json` carrying a legacy embedded `realization` section"
    - "no `.spec/realization_hashes.json`"
  when:
    - write_state/4 regenerates `.spec/state.json`
  then:
    - "`.spec/realization_hashes.json` is created carrying the embedded hashes unchanged"
    - the regenerated state.json carries no `realization` key
  covers:
    - specled.index.legacy_baseline_hoist
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.index.subject_and_decision_index
    - specled.index.canonical_state_output
    - specled.index.json_resilience
- kind: tagged_tests
  execute: true
  covers:
    - specled.index.tag_data_conditional
    - specled.index.tag_data_absent_when_disabled
- kind: tagged_tests
  execute: true
  covers:
    - specled.index.state_fully_derived
    - specled.index.legacy_baseline_hoist
```
