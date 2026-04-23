# Overlap

Semantic-overlap rejection for scenarios and requirements authored within the
same subject.

## Intent

Reject duplicate or near-duplicate spec-scenarios entries that would let two
scenarios cover the same requirement redundantly, and reject MUST-stem
collisions between requirements in the same subject. Overlap is strictly a
head-only check against `current_state`; no prior-state comparison is involved.

```yaml spec-meta
id: specled.overlap
kind: module
status: draft
summary: Head-only detector for duplicate `covers:` entries and MUST-stem collisions within a subject, run alongside AppendOnly under `BranchCheck.run/3`.
surface:
  - lib/specled_ex/overlap.ex
  - test/specled_ex/overlap_test.exs
decisions:
  - specled.decision.finding_code_budget
  - specled.decision.declarative_current_truth
```

## Requirements

```yaml spec-requirements
- id: specled.overlap.duplicate_covers
  statement: Overlap.analyze shall emit `overlap/duplicate_covers` at `:error` when two scenarios in the same subject both list the same requirement id in their `covers:` field, naming both scenario ids and the shared requirement in the finding message.
  priority: must
  stability: evolving
- id: specled.overlap.must_stem_collision
  statement: Overlap.analyze shall emit `overlap/must_stem_collision` at `:error` when two `must`-priority requirements in the same subject share the same canonicalized MUST stem (leading modal verb phrase after trimming and lowercasing), so that authors cannot accidentally duplicate normative load under separate ids.
  priority: must
  stability: evolving
- id: specled.overlap.within_subject_scope
  statement: Overlap.analyze shall scope both `duplicate_covers` and `must_stem_collision` checks within a single `subject_id`; collisions between scenarios or requirements in different subjects shall not emit overlap findings.
  priority: must
  stability: evolving
- id: specled.overlap.findings_sorted
  statement: Overlap.analyze shall return its findings list sorted by `{subject_id, entity_id, code}` with `nil` keys treated as the empty string, matching the AppendOnly output ordering contract.
  priority: must
  stability: stable
- id: specled.overlap.no_prior_state
  statement: Overlap.analyze shall take only the head-side subject and requirement lists as input; it shall not consult prior state and shall produce identical output for identical head input regardless of diff context.
  priority: must
  stability: stable
```

## Scenarios

```yaml spec-scenarios
- id: specled.overlap.scenario.duplicate_covers_same_subject
  given:
    - "a subject `x` with two scenarios `x.scenario.a` and `x.scenario.b` that both list `covers: [x.req_1]`"
  when:
    - SpecLedEx.Overlap.analyze/2 is invoked
  then:
    - "the returned findings list contains one `overlap/duplicate_covers` finding at `:error` naming both scenario ids and `x.req_1`"
  covers:
    - specled.overlap.duplicate_covers

- id: specled.overlap.scenario.must_stem_collision
  given:
    - "a subject `x` with requirement `x.req_1` statement `\"The system MUST reject invalid input.\"`"
    - "a subject `x` with requirement `x.req_2` statement `\"The system MUST reject invalid input.\"`"
  when:
    - SpecLedEx.Overlap.analyze/2 is invoked
  then:
    - "the returned findings list contains one `overlap/must_stem_collision` finding at `:error` naming both requirement ids"
  covers:
    - specled.overlap.must_stem_collision

- id: specled.overlap.scenario.cross_subject_duplicates_ignored
  given:
    - "subject `x` scenario `x.scenario.a` has `covers: [shared.req]`"
    - "subject `y` scenario `y.scenario.b` has `covers: [shared.req]`"
  when:
    - SpecLedEx.Overlap.analyze/2 is invoked
  then:
    - no `overlap/duplicate_covers` finding is emitted
  covers:
    - specled.overlap.within_subject_scope

- id: specled.overlap.scenario.output_sorted
  given:
    - a head input that would produce three overlap findings across two subjects
  when:
    - SpecLedEx.Overlap.analyze/2 is invoked
  then:
    - "the returned findings list is sorted by `{subject_id, entity_id, code}`"
  covers:
    - specled.overlap.findings_sorted

- id: specled.overlap.scenario.pure_head_only
  given:
    - "identical head inputs `h`"
  when:
    - SpecLedEx.Overlap.analyze/2 is invoked twice with `h`
  then:
    - the two returned findings lists are equal
  covers:
    - specled.overlap.no_prior_state
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/overlap_test.exs
  execute: false
  covers:
    - specled.overlap.duplicate_covers
    - specled.overlap.must_stem_collision
    - specled.overlap.within_subject_scope
    - specled.overlap.findings_sorted
    - specled.overlap.no_prior_state
- kind: source_file
  target: lib/specled_ex/overlap.ex
  execute: false
  covers:
    - specled.overlap.duplicate_covers
    - specled.overlap.must_stem_collision
    - specled.overlap.within_subject_scope
```
