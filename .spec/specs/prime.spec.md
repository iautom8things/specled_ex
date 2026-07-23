# Prime

Session-start context for agents and maintainers.

## Intent

Give one read-only command that helps a maintainer or agent understand the current workspace and branch before editing current truth.

Both default-loop variants (normal and `--bugfix`) name both resolution arms for the `needs decision update` step: revise ADRs for durable cross-cutting rules, otherwise clear the finding with a `Spec-Drift: branch_guard_missing_decision_update=info` trailer plus a one-line reason.

```yaml spec-meta
id: specled.prime
kind: workflow
status: active
summary: Combines workspace status, current-branch guidance, and the default local loop into one session-start command.
surface:
  - lib/mix/tasks/spec.prime.ex
  - lib/specled_ex/prime.ex
  - test/mix/tasks/spec_prime_task_test.exs
realized_by:
  api_boundary:
    - "Mix.Tasks.Spec.Prime.run/1"
  implementation:
    - "SpecLedEx.Prime.build/4"
    - "SpecLedEx.Prime.format_human/1"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.guided_reconciliation_loop
  - specled.decision.no_app_start
  - specled.decision.decision_fork_advertised_at_decision_points
```

## Requirements

```yaml spec-requirements
- id: specled.prime.session_context
  statement: mix spec.prime shall provide a read-only session-start summary that combines workspace status, current-branch guidance, and the default local loop for the current repository.
  priority: should
  stability: evolving
- id: specled.prime.command_execution_default
  statement: mix spec.prime shall keep command verification execution off by default and only execute eligible command verifications when --run-commands is passed.
  priority: should
  stability: evolving
- id: specled.prime.machine_output
  statement: mix spec.prime shall support JSON output that nests the workspace status report, current-branch guidance, and loop steps for agent consumption.
  priority: should
  stability: evolving
- id: specled.prime.decision_fork_loop_line
  statement: >-
    The mix spec.prime default loop, in both its normal and --bugfix
    variants, shall state both resolution arms for the `needs decision
    update` step — revising ADRs when the rule is durable and
    cross-cutting, and otherwise clearing the finding with a
    `Spec-Drift: branch_guard_missing_decision_update=info` trailer plus a
    one-line reason.
  priority: must
  stability: evolving
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.prime.session_context
    - specled.prime.command_execution_default
    - specled.prime.machine_output
    - specled.prime.decision_fork_loop_line
```
