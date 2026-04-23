# Coverage × Closure × Tags Triangulation

Cross-checks the three sides of the spec/code/test triangle and emits findings
when they disagree.

## Intent

Three claims exist per subject: the requirements (spec), the implementation
closure (code), and the `@tag spec:` markers (tests). If coverage data says test
T executed MFA M, but M belongs to subject B, and T's `@tag spec:` names
subject A, we have a tagging mismatch. Conversely, a requirement with no test
executing any MFA in its closure is `branch_guard_untested_realization`. The
module consumes `Coverage.Store`, the closure map, and the tag index; it emits
nothing if any input is missing (graceful degrade via `detector_unavailable`).

```yaml spec-meta
id: specled.triangulation
kind: workflow
status: active
summary: >-
  Pure function over `(coverage_records, closures, tag_index)` returning new
  findings `branch_guard_untested_realization`, `branch_guard_untethered_test`,
  `branch_guard_underspecified_realization`, plus `detector_unavailable` on
  missing inputs; `mix spec.triangle` prints per-subject diagnostics.
surface:
  - lib/specled_ex/coverage_triangulation.ex
  - lib/mix/tasks/spec.triangle.ex
  - test/specled_ex/coverage_triangulation_test.exs
  - test/integration/scenario_test_only_change_test.exs
  - test/integration/scenario_mistagged_test_test.exs
```

## Requirements

```yaml spec-requirements
- id: specled.triangulation.pure_function
  statement: >-
    SpecLedEx.CoverageTriangulation.findings/3 shall be a pure function
    taking `(coverage_records, closure_map, tag_index)` and returning a
    findings list. It shall not touch the filesystem, start processes,
    or consult Mix globals.
  priority: must
  stability: evolving
- id: specled.triangulation.untested_realization
  statement: >-
    When a requirement's effective binding closure contains MFAs but
    zero coverage records exercise any MFA in the closure, a
    `branch_guard_untested_realization` finding shall name the subject
    id, requirement id, and the closure MFAs.
  priority: must
  stability: evolving
- id: specled.triangulation.untethered_test
  statement: >-
    When a test carries `@tag spec: "A.req"` but its coverage records
    exercise only MFAs owned by subject `B` (not `A`), a
    `branch_guard_untethered_test` finding shall name the test file,
    the tag, and the observed owner. Default severity is `:info`.
    Per-test opt-out shall be `@tag spec_triangulation: :indirect`.
  priority: must
  stability: evolving
- id: specled.triangulation.underspecified_realization
  statement: >-
    When coverage records reach an MFA owned by subject A but the
    exercising test carries no `@tag spec:` referencing A's
    requirements, a `branch_guard_underspecified_realization` finding
    shall name the MFA, the test, and the subject. This surfaces
    silent-execution coverage that no requirement claims.
  priority: must
  stability: evolving
- id: specled.triangulation.execution_reach_metric
  statement: >-
    The returned findings list shall carry per-subject metadata
    `execution_reach: "N/M (0.FF)"` where N is requirements with any
    exercised closure, M is total requirements, and 0.FF is N/M as a
    two-digit float. CLI output renders the fraction + float form; the
    config threshold (separately) is a float in `[0.0, 1.0]`.
  priority: should
  stability: evolving
- id: specled.triangulation.detector_unavailable_on_missing_coverage
  statement: >-
    When no `.spec/_coverage/per_test.coverdata` exists (user did not
    run `mix spec.cover.test`), the module shall emit a single
    `detector_unavailable` finding with reason
    `:no_coverage_artifact` and return an otherwise empty findings
    list. No triangulation findings shall be guessed from partial data.
  priority: must
  stability: evolving
- id: specled.triangulation.spec_triangle_task
  statement: >-
    mix spec.triangle `<subject.id>` shall print per-requirement
    diagnostics: effective binding, closure MFAs, exercising tests,
    execution_reach. It is a read-only diagnostic; it shall not mutate
    state.json.
  priority: should
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.triangulation.scenario.untethered_test_flagged
  given:
    - "a test with `@tag spec: \"subject_a.req1\"` that exercises only MFAs owned by subject_b"
    - coverage records, closure map, and tag index as inputs
  when:
    - CoverageTriangulation.findings/3 is called
  then:
    - "the returned list contains a `branch_guard_untethered_test` finding naming the test and subject_b"
    - the finding severity is `:info` by default
  covers:
    - specled.triangulation.untethered_test
    - specled.triangulation.pure_function
- id: specled.triangulation.scenario.opt_out_tag_suppresses
  given:
    - the same untethered test
    - "the test also carries `@tag spec_triangulation: :indirect`"
  when:
    - CoverageTriangulation.findings/3 is called
  then:
    - no `branch_guard_untethered_test` finding references this test
  covers:
    - specled.triangulation.untethered_test
- id: specled.triangulation.scenario.cold_run_detector_unavailable
  given:
    - a project with no `.spec/_coverage/per_test.coverdata`
  when:
    - mix spec.check runs with triangulation enabled
  then:
    - "a single `detector_unavailable` finding references reason `:no_coverage_artifact`"
    - no `branch_guard_untested_realization` findings are emitted speculatively
  covers:
    - specled.triangulation.detector_unavailable_on_missing_coverage
- id: specled.triangulation.scenario.test_only_change_scenario_gate
  given:
    - a spec scenario (spec S2) whose test-only change flow
    - mix spec.cover.test run captured with fixture coverage data
    - a branch that edits only the test (no code change)
  when:
    - mix spec.check runs on the branch
  then:
    - a `branch_guard_test_only_change` summary reflects the expected flow
    - no `branch_guard_realization_drift` fires
  covers:
    - specled.triangulation.pure_function
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/coverage_triangulation_test.exs
  execute: true
  covers:
    - specled.triangulation.pure_function
    - specled.triangulation.untested_realization
    - specled.triangulation.untethered_test
    - specled.triangulation.underspecified_realization
    - specled.triangulation.execution_reach_metric
    - specled.triangulation.detector_unavailable_on_missing_coverage
- kind: command
  target: mix test test/integration/scenario_test_only_change_test.exs --include integration
  execute: true
  covers:
    - specled.triangulation.pure_function
- kind: command
  target: mix test test/integration/scenario_mistagged_test_test.exs --include integration
  execute: true
  covers:
    - specled.triangulation.untethered_test
- kind: command
  target: mix test test/mix/tasks/spec_triangle_test.exs
  execute: true
  covers:
    - specled.triangulation.spec_triangle_task
```
