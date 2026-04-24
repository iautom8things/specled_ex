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
```
