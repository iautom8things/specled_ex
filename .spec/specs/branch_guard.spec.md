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
  statement: When test-tag data is present on the index, the branch guard inside mix spec.check shall emit a finding for each `must` requirement added on the current branch whose id appears in no `@tag spec:` annotation in the configured scan paths.
  priority: must
  stability: evolving
- id: specled.branch_guard.tag_findings_respect_enforcement
  statement: The branch guard shall honor `test_tags.enforcement` when promoting new-untagged-requirement findings to error severity.
  priority: should
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.branch_guard.scenario.new_requirement_without_tag
  given:
    - a branch that adds a new `must` requirement `billing.invoice` to an existing subject
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
- kind: command
  target: mix test test/mix/tasks/spec_tasks_test.exs
  execute: true
  covers:
    - specled.branch_guard.subject_cochange
    - specled.branch_guard.cross_cutting_decision
    - specled.branch_guard.guidance_output
    - specled.branch_guard.plan_docs_excluded
- kind: command
  target: mix test test/specled_ex/branch_check_test.exs
  execute: true
  covers:
    - specled.branch_guard.new_requirement_tag_warning
    - specled.branch_guard.tag_findings_respect_enforcement
```
