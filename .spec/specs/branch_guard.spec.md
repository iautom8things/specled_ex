# Branch Guard

Diff-aware co-change validation for current-truth subject specs and durable ADRs.

## Intent

Catch code, docs, and test changes that move ahead of current-truth specs or skip a needed cross-cutting ADR update.

```yaml spec-meta
id: specled.branch_guard
kind: workflow
status: active
summary: Uses the current Git change set to enforce subject co-changes and cross-cutting ADR updates during the final local check.
surface:
  - lib/specled_ex/branch_check.ex
  - lib/specled_ex/coverage.ex
  - lib/mix/tasks/spec.check.ex
  - lib/specled_ex/config/branch_guard.ex
  - lib/specled_ex/realization/orchestrator.ex
  - test/specled_ex/config/branch_guard_test.exs
  - test/specled_ex/branch_check/load_prior_state_test.exs
  - test/specled_ex/realization/orchestrator_test.exs
  - test/integration/scenario_tier_dispatch_test.exs
realized_by:
  api_boundary:
    - "Mix.Tasks.Spec.Check.run/1"
    - "SpecLedEx.Realization.Orchestrator.run/2"
  implementation:
    - "SpecLedEx.BranchCheck.run/3"
    - "SpecLedEx.Coverage"
    - "SpecLedEx.Config.BranchGuard"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.guided_reconciliation_loop
  - specled.decision.no_app_start
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.file_touch_yields_to_realization
```

## Requirements

```yaml spec-requirements
- id: specled.branch_guard.subject_cochange
  statement: The branch guard inside mix spec.check shall fail when changed code, tests, guides, templates, skills, or governed package files are not matched by current-truth subject spec updates for the impacted subjects, including unmapped changed policy files outside current subject coverage.
  priority: must
  stability: evolving
- id: specled.branch_guard.cross_cutting_decision
  statement: The branch guard inside mix spec.check shall fail with an error finding when a cross-cutting change spans multiple impacted subjects without a matching ADR update.
  priority: must
  stability: evolving
- id: specled.branch_guard.guidance_output
  statement: The branch guard inside mix spec.check shall append additive guidance that reports the change type, impacted subjects or uncovered policy files, and the suggested mix spec.next command without changing its enforcement semantics.
  priority: should
  stability: evolving
- id: specled.branch_guard.plan_docs_excluded
  statement: The branch guard inside mix spec.check shall ignore branch-local planning notes under docs/plans/ when evaluating policy co-changes.
  priority: should
  stability: evolving
- id: specled.branch_guard.new_requirement_tag_warning
  statement: >-
    When test-tag data is present on the index, the branch guard inside mix
    spec.check shall emit a finding for each `must` requirement added on the
    current branch that is covered by at least one `tagged_tests` verification
    on its owning subject and whose id appears in no `@tag spec:` annotation
    in the configured scan paths. Requirements covered exclusively by
    non-`tagged_tests` kinds shall not produce this finding.
  priority: must
  stability: evolving
- id: specled.branch_guard.tag_findings_respect_enforcement
  statement: The branch guard shall honor `test_tags.enforcement` when promoting new-untagged-requirement findings to error severity.
  priority: should
  stability: evolving
- id: specled.branch_guard.tier_dispatch_wires_orchestrator
  statement: >-
    `SpecLedEx.BranchCheck.run/3` shall invoke
    `SpecLedEx.Realization.Orchestrator.run/2` and merge its returned findings
    into the branch report. The orchestrator shall walk every subject's
    subject-level and requirement-level `realized_by:` blocks, dispatch each
    declared tier to its corresponding `SpecLedEx.Realization.*` entrypoint,
    and return string-keyed finding maps. No new `Mix.env/0` or
    `Mix.Project.config/0` reads shall appear at tier call sites; the
    orchestrator threads a `%SpecLedEx.Compiler.Context{}` through explicitly.
  priority: must
  stability: evolving
- id: specled.branch_guard.tier_dispatch_surfaces_drift
  statement: >-
    When a declared binding's current hash differs from the committed hash in
    `.spec/state.json`, the branch report shall include a
    `branch_guard_realization_drift` finding naming the subject id, tier, and
    the MFA (or provider module for the use tier). The finding's severity
    shall flow through `SpecLedEx.BranchCheck.Severity.resolve/3` with the
    same precedence rules as existing codes (trailer override > config >
    default `:warning`).
  priority: must
  stability: evolving
- id: specled.branch_guard.tier_dispatch_surfaces_dangling
  statement: >-
    When a declared binding does not resolve to a live MFA or module, the
    branch report shall include a `branch_guard_dangling_binding` finding at
    default severity `:error`, naming the subject id, tier, and offending
    binding. Remediation text shall be copy-pastable for an agent prompt.
  priority: must
  stability: evolving
- id: specled.branch_guard.tier_dispatch_commits_hashes_on_clean
  statement: >-
    On a run that produced neither drift nor dangling findings, the
    orchestrator shall commit current hashes for the four flat-binding tiers
    (`api_boundary`, `expanded_behavior`, `typespecs`, `use`) to `HashStore`
    via `HashStore.write/2`. When drift or dangling findings are present, the
    orchestrator shall NOT overwrite committed hashes. The implementation tier
    is excluded from hash commit in this revision because its hash refresh
    requires a `world` map whose construction lives inside `Implementation`'s
    private API.
  priority: must
  stability: evolving
- id: specled.branch_guard.tier_dispatch_umbrella_degrades
  statement: >-
    When `opts[:umbrella?]` is true, the orchestrator shall dispatch every
    enabled tier with `umbrella?: true` regardless of binding presence. Each
    tier shall emit a single `detector_unavailable` finding with `reason:
    :umbrella_unsupported` and shall not raise.
  priority: must
  stability: evolving
- id: specled.branch_guard.tier_dispatch_impl_opt_in
  statement: >-
    `SpecLedEx.Realization.Orchestrator.default_tiers/0` shall return the four
    flat-binding tiers (`api_boundary`, `expanded_behavior`, `typespecs`,
    `use`). The `implementation` tier is opt-in via `enabled_tiers:` for this
    revision because dispatching it against real repo bindings surfaces a
    pre-existing AST shape mismatch between `Binding.resolve/2` and
    `Canonical.normalize/1`. A follow-up ticket tracks reshaping one of the
    two call sites so the impl tier can be enabled by default.
  priority: must
  stability: evolving
- id: specled.branch_guard.file_touch_yields_to_attested_file
  statement: >-
    `SpecLedEx.BranchCheck.run/3` shall, for each
    `branch_guard_missing_subject_update` candidate `(file, subject)` pair,
    consult the realization tier's attestation map. When the pair is
    `:attested_clean` (i.e. at least one of the subject's `realized_by`
    bindings resolves to `file` and is not in this run's drift/dangling
    finding set), the finding shall be emitted with the call-site default
    severity `:info` and a distinctive message naming the attesting
    binding(s). When the pair is not attested clean (no resolving binding
    names this file, the binding drifted, or the detector was unavailable),
    the finding shall be emitted with the call-site default severity
    `:error` and the original message. The finding code remains
    `branch_guard_missing_subject_update` in both branches.
  priority: must
  stability: evolving
- id: specled.branch_guard.file_touch_per_subject_independence
  statement: >-
    When a single changed file impacts multiple subjects, the attestation
    decision for each subject's `branch_guard_missing_subject_update`
    finding shall be made independently per-subject. One file impacting
    subject A (attested clean) and subject B (no `realized_by` or drifted)
    shall produce two findings in the same run — one at the attested
    default `:info` naming A, one at the strict default `:error` naming B.
  priority: must
  stability: evolving
- id: specled.branch_guard.file_touch_severity_config_wins
  statement: >-
    The attested-default downgrade shall flow through
    `SpecLedEx.BranchCheck.Severity.resolve/3` as the `default` argument.
    A project-level severity override pinning
    `branch_guard_missing_subject_update` to `:error` (or any other level)
    in `branch_guard.severities` shall win over the attested default, and
    `:off` shall continue to absorb both trailer overrides and the
    relaxation.
  priority: must
  stability: evolving
- id: specled.branch_guard.file_touch_tagged_tests_attested
  statement: >-
    When a subject's `verification` block contains a `kind: tagged_tests`
    entry whose `covers:` list points at requirements with `realized_by`
    bindings that attest clean on this run, the test files looked up via
    `index["test_tags"][requirement_id]` shall participate in attestation
    for that subject under the same predicate as production-code files
    (path equality after normalization, binding not in drift/dangling set).
    The attestation reason names the same binding(s) that attested the
    covered requirement.
  priority: must
  stability: evolving
- id: specled.branch_guard.file_touch_detector_failure_strict
  statement: >-
    When the realization tier emits `detector_unavailable` for the tier
    providing a binding (or the path-aware resolver returns no source path
    for that binding), the resulting attestation entry shall be absent
    from the attestation map for the affected `(subject, file)` pair, and
    the file-touch guard shall fall back to the strict `:error` default.
    Detector failure shall not silently relax the guard.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.branch_guard.scenario.new_requirement_without_tag
  given:
    - a branch that adds a new `must` requirement `billing.invoice` to an existing subject
    - that subject declares a `tagged_tests` verification covering `billing.invoice`
    - a tag_map that does not contain `billing.invoice`
  when:
    - mix spec.check runs against the branch base
  then:
    - a finding is produced naming `billing.invoice` and the file where it was added
  covers:
    - specled.branch_guard.new_requirement_tag_warning
- id: specled.branch_guard.scenario.enforcement_error_escalates_finding
  given:
    - the same new untagged requirement as above
    - "a config that sets test_tags.enforcement to :error"
  when:
    - mix spec.check runs
  then:
    - the finding severity is error
    - mix spec.check exits non-zero
  covers:
    - specled.branch_guard.tag_findings_respect_enforcement
- id: specled.branch_guard.scenario.file_touch_attested_clean_downgrades
  given:
    - "a subject `voyd_config.component` with `realized_by.api_boundary: [\"VoydConfig.Component.new/2\"]`"
    - "the binding's committed hash matches the current canonical AST"
    - "the author makes a comment-only edit inside `def new/2` in `lib/voyd_config/component/component.ex`"
    - "the spec.md file for `voyd_config.component` is not co-changed"
  when:
    - "mix spec.check runs"
  then:
    - "a `branch_guard_missing_subject_update` finding fires at severity `info`"
    - "the finding message names the attesting binding `VoydConfig.Component.new/2`"
    - "mix spec.check exits zero"
  covers:
    - specled.branch_guard.file_touch_yields_to_attested_file
- id: specled.branch_guard.scenario.file_touch_drift_no_relaxation
  given:
    - "the same subject and binding as above"
    - "the author edits `def new/2` in a way that changes the canonical AST (e.g. adds a new clause)"
    - "the spec.md is not co-changed"
  when:
    - "mix spec.check runs"
  then:
    - "a `branch_guard_realization_drift` finding fires for `VoydConfig.Component.new/2`"
    - "the `branch_guard_missing_subject_update` finding fires at severity `error` with the original message"
    - "mix spec.check exits non-zero"
  covers:
    - specled.branch_guard.file_touch_yields_to_attested_file
- id: specled.branch_guard.scenario.file_touch_surface_only_unbound_stays_strict
  given:
    - "a subject with `surface: [\"lib/voyd_config/component/\"]` (directory glob)"
    - "the subject has `realized_by.api_boundary` naming `VoydConfig.Component.new/2` only"
    - "the author edits `lib/voyd_config/component/internal_helpers.ex` (in the surface glob, not in any binding)"
    - "the spec.md is not co-changed"
  when:
    - "mix spec.check runs"
  then:
    - "a `branch_guard_missing_subject_update` finding fires at severity `error` with the original message"
    - "mix spec.check exits non-zero"
  covers:
    - specled.branch_guard.file_touch_yields_to_attested_file
- id: specled.branch_guard.scenario.file_touch_multi_subject_partial_attestation
  given:
    - "a file `lib/shared/util.ex` that maps to subjects `subj_a` and `subj_b`"
    - "`subj_a` has a clean `realized_by` binding naming `Shared.Util.run/1` in `lib/shared/util.ex`"
    - "`subj_b` has no `realized_by` bindings"
    - "the author edits `lib/shared/util.ex` and does not touch either spec.md"
  when:
    - "mix spec.check runs"
  then:
    - "two `branch_guard_missing_subject_update` findings fire"
    - "the finding naming `subj_a` is at severity `info` and names binding `Shared.Util.run/1`"
    - "the finding naming `subj_b` is at severity `error` with the original message"
    - "mix spec.check exits non-zero (because of `subj_b`)"
  covers:
    - specled.branch_guard.file_touch_per_subject_independence
- id: specled.branch_guard.scenario.file_touch_severity_pin_overrides_attestation
  given:
    - "the same attested-clean comment-only edit as `file_touch_attested_clean_downgrades`"
    - "a project config that sets `branch_guard.severities.branch_guard_missing_subject_update: :error`"
  when:
    - "mix spec.check runs"
  then:
    - "the `branch_guard_missing_subject_update` finding fires at severity `error` regardless of attestation"
    - "mix spec.check exits non-zero"
  covers:
    - specled.branch_guard.file_touch_severity_config_wins
- id: specled.branch_guard.scenario.file_touch_tagged_test_attested
  given:
    - "a subject with a requirement `req.a` carrying `realized_by.api_boundary: [\"Mod.f/1\"]` that attests clean"
    - "the subject has a `kind: tagged_tests` verification with `covers: [req.a]`"
    - "`index[\"test_tags\"][\"req.a\"]` resolves to `[%{file: \"test/mod_test.exs\"}]`"
    - "the author makes a comment-only edit to `test/mod_test.exs` and does not touch spec.md"
  when:
    - "mix spec.check runs"
  then:
    - "the `branch_guard_missing_subject_update` finding for the test file fires at severity `info`"
    - "the finding names the attesting binding `Mod.f/1`"
  covers:
    - specled.branch_guard.file_touch_tagged_tests_attested
- id: specled.branch_guard.scenario.file_touch_detector_failure_falls_back_strict
  given:
    - "a subject whose `realized_by` bindings would otherwise attest a changed file as clean"
    - "the realization run produces a `detector_unavailable` finding for the tier that owns those bindings"
  when:
    - "mix spec.check runs"
  then:
    - "the `branch_guard_missing_subject_update` finding fires at severity `error` with the original message"
    - "the `detector_unavailable` finding is also present"
  covers:
    - specled.branch_guard.file_touch_detector_failure_strict
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.branch_guard.subject_cochange
    - specled.branch_guard.cross_cutting_decision
    - specled.branch_guard.guidance_output
    - specled.branch_guard.plan_docs_excluded
- kind: tagged_tests
  execute: true
  covers:
    - specled.branch_guard.new_requirement_tag_warning
    - specled.branch_guard.tag_findings_respect_enforcement
- kind: command
  target: mix test test/specled_ex/realization/orchestrator_test.exs
  execute: true
  covers:
    - specled.branch_guard.tier_dispatch_wires_orchestrator
    - specled.branch_guard.tier_dispatch_commits_hashes_on_clean
    - specled.branch_guard.tier_dispatch_umbrella_degrades
    - specled.branch_guard.tier_dispatch_impl_opt_in
- kind: command
  target: mix test test/integration/scenario_tier_dispatch_test.exs
  execute: true
  covers:
    - specled.branch_guard.tier_dispatch_wires_orchestrator
    - specled.branch_guard.tier_dispatch_surfaces_drift
    - specled.branch_guard.tier_dispatch_surfaces_dangling
- kind: tagged_tests
  execute: false
  covers:
    - specled.branch_guard.file_touch_yields_to_attested_file
    - specled.branch_guard.file_touch_per_subject_independence
    - specled.branch_guard.file_touch_severity_config_wins
    - specled.branch_guard.file_touch_tagged_tests_attested
    - specled.branch_guard.file_touch_detector_failure_strict
```
