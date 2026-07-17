# Index And State

Index building and explicit derived-state persistence for the Spec Led Development workspace.

## Intent

Define how the package discovers authored current-truth subjects and ADRs, then
normalizes a stable derived state artifact only when a caller explicitly asks
for one.

```yaml spec-meta
id: specled.index_state
kind: workflow
status: active
summary: Builds the authored index and writes canonical derived state only on explicit request.
surface:
  - lib/specled_ex.ex
  - lib/specled_ex/base_view.ex
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
  statement: Explicit state writing shall normalize indexed entities, findings, verification data, and decisions into a canonical derived-state artifact with stable ordering and no volatile persisted fields; mix tasks shall not write `.spec/state.json` by default, and mix spec.index / mix spec.validate may write the artifact only when `--output` is supplied.
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
    When the legacy `.spec/state.json` still carries an embedded
    `realization` section and `.spec/realization_hashes.json` is absent,
    `mix spec.evidence.migrate` shall hoist the embedded section into the
    dedicated baseline file before untracking state.json, so the committed
    hashes survive the migration instead of being silently re-seeded from the
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
- id: specled.index.base_view_parses_base_sources
  statement: >-
    `SpecLedEx.BaseView.build/3` shall enumerate the base tree's authored spec
    and decision paths with `git ls-tree -r --name-only <base> -- <authored_dir>
    <decision_dir>`, materialize the listed blobs into an isolated temporary
    `.spec` workspace, parse that workspace with `SpecLedEx.Index.build/2` using
    current parser code and disabled test-tag scanning, return
    `SpecLedEx.normalize_for_state/1` plus parsed decisions, and remove the
    temporary workspace before returning.
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
    - write_state/4 explicitly regenerates `.spec/state.json`
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
    - state.json is explicitly regenerated
  then:
    - HashStore.read/1 still returns the committed baseline (it is preserved, not recomputed)
  covers: []
- id: specled.index.scenario.legacy_hoist_on_regen
  given:
    - "a `.spec/state.json` carrying a legacy embedded `realization` section"
    - "no `.spec/realization_hashes.json`"
  when:
    - mix spec.evidence.migrate hoists legacy realization
  then:
    - "`.spec/realization_hashes.json` is created carrying the embedded hashes unchanged"
    - the dedicated baseline file is created without rewriting the legacy state file
  covers:
    - specled.index.legacy_baseline_hoist
- id: specled.index.scenario.base_view_deleted_head_file
  given:
    - "a base commit with two authored spec files"
    - "one of those files is deleted from the head working tree"
  when:
    - "`SpecLedEx.BaseView.build/3` parses the base ref"
  then:
    - "the deleted-at-head file still appears in the returned base state"
    - "the returned base state matches a live parse of the same base content"
  covers:
    - specled.index.base_view_parses_base_sources
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
- kind: tagged_tests
  execute: true
  covers:
    - specled.index.base_view_parses_base_sources
```
