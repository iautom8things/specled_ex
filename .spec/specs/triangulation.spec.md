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
  missing inputs; `mix spec.triangle` prints targeted or all-subject diagnostics.
  Additive v2 envelope path (`envelope_findings/3`,
  `aggregate_requirement_reach/2`) consumes a `Coverage.Store` v2 envelope
  directly instead of a raw per-test record list — see
  `specled.triangulation.envelope_*` requirements below. The v1 functions and
  `mix spec.triangle` are unchanged; only `mix spec.triangle` and `mix
  spec.review` may ever consume either path (Decision: never `mix spec.check`).
surface:
  - lib/specled_ex/coverage_triangulation.ex
  - lib/specled_ex/review/coverage_closure.ex
  - lib/mix/tasks/spec.triangle.ex
  - test/specled_ex/coverage_triangulation_test.exs
  - test/specled_ex/review/coverage_closure_test.exs
  - test/integration/scenario_test_only_change_test.exs
  - test/integration/scenario_mistagged_test_test.exs
realized_by:
  api_boundary:
    - "Mix.Tasks.Spec.Triangle.run/1"
  implementation:
    - "SpecLedEx.CoverageTriangulation.findings/3"
    - "SpecLedEx.CoverageTriangulation.envelope_findings/3"
    - "SpecLedEx.CoverageTriangulation.aggregate_requirement_reach/2"
    - "SpecLedEx.Review.CoverageClosure.build_v2/2"
    - "SpecLedEx.CoverageTriangulation.execution_reach_map/2"
decisions:
  - specled.decision.aggregate_first_spec_coverage
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
  priority: must
  stability: evolving
- id: specled.triangulation.untethered_test_opt_out
  statement: >-
    A test that would otherwise trigger
    `branch_guard_untethered_test` shall be suppressed (no finding
    emitted for it) when the test carries
    `@tag spec_triangulation: :indirect`, providing an explicit
    per-test opt-out for intentional indirect coverage.
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
    mix spec.triangle shall print per-requirement diagnostics for all
    indexed subject specs by default or when passed `--all`, and for one
    subject when passed `<subject.id>`. Diagnostics shall include effective
    binding, closure MFAs, exercising tests, and execution_reach. It reads
    the v2 coverage envelope and prints its `mode` (`aggregate` or
    `per_test`); in `:aggregate` mode it additionally prints each
    requirement's closure-coverage percentage from
    `CoverageTriangulation.aggregate_requirement_reach/2` and labels the
    per-test-only detectors `detector_unavailable` (reason
    `aggregate_artifact_only`) via `CoverageTriangulation.envelope_findings/3`
    rather than omitting them silently. A missing, legacy, invalid, or
    async-contaminated per-test artifact each print their own distinct
    `detector_unavailable` note. It is a read-only diagnostic; it shall not
    mutate state.json.
  priority: should
  stability: evolving
- id: specled.triangulation.envelope_legacy_and_invalid_distinct
  statement: >-
    `CoverageTriangulation.envelope_findings/3` shall emit a single
    `detector_unavailable` finding whose `reason` is `no_coverage_artifact`,
    `legacy_artifact`, or `invalid_artifact` for the matching degraded input
    (mirroring `Coverage.Store.read_v2/1`'s three-way distinction), and these
    three reasons shall never collapse into one another or into an
    empty-but-ok findings list.
  priority: must
  stability: evolving
- id: specled.triangulation.envelope_aggregate_untested_realization
  statement: >-
    Given an `:aggregate` v2 envelope, `envelope_findings/3` shall emit
    `branch_guard_untested_realization` for a requirement whose realization
    closure has one or more MFAs (`closure_mfas`) but where none of them are
    marked `covered: true` in the envelope's `:mfas` list. It shall not use
    the v1 per-record `lines_hit != []` heuristic — coverage in aggregate
    mode is read directly from each MFA's `:covered` boolean.
  priority: must
  stability: evolving
- id: specled.triangulation.envelope_per_test_only_detectors_unavailable
  statement: >-
    Given an `:aggregate` v2 envelope, `envelope_findings/3` shall emit
    exactly one `detector_unavailable` finding with reason
    `aggregate_artifact_only`, naming `branch_guard_untethered_test`, the
    per-test form of `branch_guard_underspecified_realization`, and
    `reaching_tests` as unavailable — aggregate coverage carries no per-test
    attribution, so these detectors cannot run. `aggregate_requirement_reach/2`
    shall never include a `:reaching_tests` field in its return value (that
    field is exclusive to the `:per_test`-path `per_requirement_reach/2`).
  priority: must
  stability: evolving
- id: specled.triangulation.envelope_aggregate_underspecified_realization
  statement: >-
    Given an `:aggregate` v2 envelope, `envelope_findings/3` shall emit an
    aggregate-specific `branch_guard_underspecified_realization` finding
    (tagged `"mode" => "aggregate"`) for a subject where the envelope shows
    at least one requirement's closure with a nonzero `executed_mfa_count`,
    but the tag index carries zero `@tag spec:` entries for any of that
    subject's requirements. This is derived from the tag index alone, not
    per-test coverage, and is distinct from the v1 file-attributed
    `branch_guard_underspecified_realization` emitted by `findings/3`.
  priority: must
  stability: evolving
- id: specled.triangulation.envelope_async_contaminated
  statement: >-
    Given a `:per_test` v2 envelope with `degraded: true` (the `--per-test`
    lane's async-contamination guard), `envelope_findings/3` shall emit a
    single `detector_unavailable` finding with reason `async_contaminated`
    instead of computing per-test findings over data that may be corrupted.
    A non-degraded `:per_test` envelope shall delegate its `:payload` to
    `findings/3` unchanged.
  priority: must
  stability: evolving
- id: specled.triangulation.aggregate_requirement_reach_mfa_intersection
  statement: >-
    `aggregate_requirement_reach/2` shall return, per `{subject_id,
    requirement_id}`, `closure_mfa_count`, `executed_mfa_count`,
    `covered_mfas`/`uncovered_mfas` (sorted MFA strings via
    `SpecLedEx.Coverage.MfaKey`) computed as the intersection of the
    requirement's closure MFAs with the envelope's `:mfas` list, and
    `line_coverage_pct` computed from the envelope's `:files` entries whose
    module is reached by an intersecting covered MFA.
  priority: must
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
- id: specled.triangulation.scenario.opt_out_tag_suppresses
  given:
    - the same untethered test
    - "the test also carries `@tag spec_triangulation: :indirect`"
  when:
    - CoverageTriangulation.findings/3 is called
  then:
    - no `branch_guard_untethered_test` finding references this test
  covers:
    - specled.triangulation.untethered_test_opt_out
- id: specled.triangulation.scenario.cold_run_detector_unavailable
  given:
    - a project with no `.spec/_coverage/per_test.coverdata`
  when:
    - "`CoverageTriangulation.findings/3` is called directly, or `mix spec.triangle` / `mix spec.review` runs against the project — `mix spec.check` never runs triangulation and is not a consumer of this detector (Decision 1, `specled.decision.aggregate_first_spec_coverage`)"
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
    - no `branch_guard_untested_realization` fires (the closure is still exercised)
    - no `branch_guard_realization_drift` fires
  covers:
    - specled.triangulation.pure_function
- id: specled.triangulation.scenario.envelope_degraded_statuses_distinct
  given:
    - "the three degraded envelope statuses `:no_coverage_artifact`, `:legacy_artifact`, `:invalid_artifact`"
  when:
    - CoverageTriangulation.envelope_findings/3 is called with each in turn
  then:
    - each call returns exactly one `detector_unavailable` finding naming its own reason
    - no two of the three share the same reason
  covers:
    - specled.triangulation.envelope_legacy_and_invalid_distinct
- id: specled.triangulation.scenario.envelope_aggregate_untested_and_unavailable
  given:
    - "an `:aggregate` envelope whose `:mfas` marks a requirement's only closure MFA `covered: false`"
  when:
    - CoverageTriangulation.envelope_findings/3 is called
  then:
    - "the returned list contains a `branch_guard_untested_realization` finding for that requirement"
    - "the returned list contains exactly one `detector_unavailable` finding with reason `aggregate_artifact_only`"
    - no `branch_guard_untethered_test` finding is ever emitted
  covers:
    - specled.triangulation.envelope_aggregate_untested_realization
    - specled.triangulation.envelope_per_test_only_detectors_unavailable
- id: specled.triangulation.scenario.envelope_aggregate_underspecified_from_tag_index
  given:
    - "an `:aggregate` envelope where subject A's closure MFA is `covered: true`"
    - a tag index with zero `@tag spec:` entries for any of subject A's requirements
  when:
    - CoverageTriangulation.envelope_findings/3 is called
  then:
    - "the returned list contains a `branch_guard_underspecified_realization` finding tagged `\"mode\" => \"aggregate\"` naming subject A"
  covers:
    - specled.triangulation.envelope_aggregate_underspecified_realization
- id: specled.triangulation.scenario.envelope_per_test_async_contaminated
  given:
    - "a `:per_test` envelope with `degraded: true`"
  when:
    - CoverageTriangulation.envelope_findings/3 is called
  then:
    - "the returned list is exactly one `detector_unavailable` finding with reason `async_contaminated`"
  covers:
    - specled.triangulation.envelope_async_contaminated
- id: specled.triangulation.scenario.aggregate_reach_covered_uncovered_split
  given:
    - "an `:aggregate` envelope's `:mfas` list and a closure map whose requirements declare `closure_mfas`"
  when:
    - CoverageTriangulation.aggregate_requirement_reach/2 is called
  then:
    - "each `{subject_id, requirement_id}` entry's `covered_mfas`/`uncovered_mfas` partition the requirement's closure MFAs by the envelope's `:covered` flag"
    - "`line_coverage_pct` reflects the envelope `:files` entries for modules reached by a covered closure MFA"
  covers:
    - specled.triangulation.aggregate_requirement_reach_mfa_intersection
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.triangulation.pure_function
    - specled.triangulation.untested_realization
    - specled.triangulation.untethered_test
    - specled.triangulation.untethered_test_opt_out
    - specled.triangulation.underspecified_realization
    - specled.triangulation.execution_reach_metric
    - specled.triangulation.detector_unavailable_on_missing_coverage
- kind: tagged_tests
  execute: true
  covers:
    - specled.triangulation.pure_function
- kind: tagged_tests
  execute: true
  covers:
    - specled.triangulation.untethered_test
    - specled.triangulation.untethered_test_opt_out
- kind: tagged_tests
  execute: true
  covers:
    - specled.triangulation.spec_triangle_task
- kind: tagged_tests
  execute: true
  covers:
    - specled.triangulation.envelope_legacy_and_invalid_distinct
    - specled.triangulation.envelope_aggregate_untested_realization
    - specled.triangulation.envelope_per_test_only_detectors_unavailable
    - specled.triangulation.envelope_aggregate_underspecified_realization
    - specled.triangulation.envelope_async_contaminated
    - specled.triangulation.aggregate_requirement_reach_mfa_intersection
```
