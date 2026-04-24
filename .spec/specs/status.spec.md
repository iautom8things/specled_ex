# Status

Coverage and weak-spot reporting for the current Spec Led Development workspace.

## Intent

Summarize what the workspace covers now without introducing persistent in-flight planning artifacts.

```yaml spec-meta
id: specled.status
kind: workflow
status: active
summary: Builds current-state summaries for coverage, verification strength, weak spots, and ADR usage.
surface:
  - lib/specled_ex/status.ex
  - lib/specled_ex/coverage.ex
  - lib/mix/tasks/spec.status.ex
realized_by:
  api_boundary:
    - "Mix.Tasks.Spec.Status.run/1"
  implementation:
    - "SpecLedEx.Status.build/3"
    - "SpecLedEx.Status.format_human/1"
    - "SpecLedEx.Coverage.covered_files/2"
    - "SpecLedEx.Coverage.subject_file_map/2"
    - "SpecLedEx.Coverage.category_summary/3"
    - "SpecLedEx.Coverage.subject_id/1"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.explicit_subject_ownership
  - specled.decision.guided_reconciliation_loop
  - specled.decision.no_app_start
```

## Requirements

```yaml spec-requirements
- id: specled.status.coverage_summary
  statement: mix spec.status shall summarize source, guide, and test coverage plus weak spots by subject from the current workspace, using executed command proof by default unless explicitly disabled.
  priority: should
  stability: evolving
- id: specled.status.frontier_summary
  statement: mix spec.status shall include frontier data for uncovered source, guide, and test files plus short next-gap hints for brownfield adoption.
  priority: should
  stability: evolving
- id: specled.status.decision_index
  statement: state output and mix spec.status shall summarize indexed ADRs and subject-to-ADR references.
  priority: must
  stability: evolving
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.status.coverage_summary
    - specled.status.frontier_summary
    - specled.status.decision_index
```
