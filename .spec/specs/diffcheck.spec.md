# Diffcheck

Diff-aware co-change validation for current-truth subject specs and durable ADRs.

## Intent

Catch code, docs, and test changes that move ahead of current-truth specs or skip a needed cross-cutting ADR update.

```spec-meta
id: specled.diffcheck
kind: workflow
status: active
summary: Uses the current Git diff to enforce subject co-changes and cross-cutting ADR updates.
surface:
  - lib/specled_ex/diffcheck.ex
  - lib/specled_ex/coverage.ex
  - lib/mix/tasks/spec.diffcheck.ex
decisions:
  - specled.decision.declarative_current_truth
```

## Requirements

```spec-requirements
- id: specled.diffcheck.subject_cochange
  statement: spec.diffcheck shall fail when changed code, docs, or tests are not matched by current-truth subject spec updates for the impacted subjects.
  priority: must
  stability: evolving
- id: specled.diffcheck.cross_cutting_decision
  statement: spec.diffcheck shall fail when a cross-cutting change spans multiple impacted subjects without a matching ADR update.
  priority: must
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/mix/tasks/spec_tasks_test.exs
  execute: true
  covers:
    - specled.diffcheck.subject_cochange
    - specled.diffcheck.cross_cutting_decision
```
