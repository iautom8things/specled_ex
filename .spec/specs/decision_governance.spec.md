# Decision Governance

ADR parsing and validation rules for durable cross-cutting decisions.

## Intent

Define how `.spec/decisions/*.md` files are structured and how subject specs connect to them.

```yaml spec-meta
id: specled.decisions
kind: workflow
status: active
summary: Parses ADRs, validates their contract, and lets subject specs reference durable cross-cutting decisions.
surface:
  - lib/specled_ex/decision_parser.ex
  - lib/specled_ex/decision_parser/cross_field.ex
  - lib/specled_ex/index.ex
  - lib/specled_ex/schema/decision.ex
  - lib/specled_ex/verifier.ex
  - test/specled_ex/verifier_test.exs
realized_by:
  api_boundary:
    - "SpecLedEx.DecisionParser.parse_file/4"
    - "SpecLedEx.DecisionParser.CrossField.validate/3"
    - "SpecLedEx.Schema.Decision"
  implementation:
    - "SpecLedEx.Verifier.verify_decision/4"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.change_type_enum_v1
  - specled.decision.adr_append_only
  - specled.decision.deprecates_affect_reference_carveout
  - specled.decision.repo_namespace_affect_carveout
  - specled.decision.live_cross_field_gate
```

## Requirements

```yaml spec-requirements
- id: specled.decisions.frontmatter_contract
  statement: ADR files shall require YAML frontmatter with id, status, date, and affects plus Context, Decision, and Consequences sections.
  priority: must
  stability: stable
- id: specled.decisions.reference_validation
  statement: >-
    The verifier shall reject ADR affects or supersession links that do not
    resolve, except that (1) `change_type: deprecates` ADRs may list affects
    ids absent from the current index because the target is being retired,
    and (2) ADR `affects:` ids in the reserved `repo.` prefix namespace are
    repo-scoped governance identifiers that intentionally resolve against
    nothing in the index and are accepted without resolution — the namespace
    names repo-level policy areas, not spec subjects, requirements, or ADR
    ids, and acceptance is a literal `String.starts_with?/2` prefix test, not
    a registry lookup — and shall warn when a subject references an unknown
    ADR id.
  priority: must
  stability: evolving
- id: specled.decisions.change_type_enum
  statement: >-
    ADR frontmatter shall accept an optional `change_type:` field whose
    value is one of `deprecates`, `weakens`, `narrows-scope`,
    `adds-exception`, `supersedes`, `clarifies`, or `refines`; values
    outside this set shall be rejected at schema parse. `refines` shall be
    available for accepted ADRs that sharpen an existing policy without
    weakening prior current truth.
  priority: must
  stability: stable
- id: specled.decisions.weakening_set
  statement: >-
    The weakening set that authorizes AppendOnly exceptions shall be
    exactly `{deprecates, weakens, narrows-scope, adds-exception}`;
    `supersedes` shall not authorize weakening on its own (the
    replacement requirement still goes through R1.a..R1.d), and
    `clarifies` / `refines` shall authorize no weakening.
  priority: must
  stability: stable
- id: specled.decisions.change_type_optional
  statement: >-
    ADRs without a `change_type:` field shall parse successfully and
    emit a `cross_field/missing_change_type` warning-level diagnostic
    rather than a parse error, so that legacy ADRs and bootstrap
    adoption paths are not broken.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_supersedes_replaces
  statement: >-
    The CrossField validator shall emit an error for any ADR whose
    `change_type` is `supersedes` when `replaces:` is absent or empty,
    and shall emit an error when any id in `replaces:` does not resolve
    in the current index.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_reverses_what
  statement: >-
    The CrossField validator shall emit an error when an ADR whose
    `change_type` is in the weakening set carries an empty (after
    `String.trim/1`) or missing `reverses_what:` value.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_affects_non_empty
  statement: >-
    The CrossField validator shall emit an error when an ADR with any
    non-`clarifies` `change_type` (including nil) carries an empty
    `affects:` list, except that a nil `change_type` is handled by the
    separate missing_change_type warning rather than as an affects
    error.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_affects_resolve
  statement: >-
    The CrossField validator shall emit an error when an `affects:` id
    does not resolve in the current index, except that
    `change_type: deprecates` exempts its `affects:` targets from the
    resolution check (the point of deprecation is that the target id
    is being removed), and except that ids in the reserved `repo.` prefix
    namespace are accepted without resolution (literal
    `String.starts_with?/2` prefix test; the namespace names repo-level
    policy areas, not spec subjects, requirements, or ADR ids).
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_adr_append_only
  statement: >-
    When a prior-state decision list is supplied, the CrossField
    validator shall emit an error for every ADR whose `affects`,
    `change_type`, or `reverses_what` differs from the prior-state
    version, and shall emit an error for any status transition other
    than `accepted` → `deprecated` or `accepted` → `superseded`.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_live_gate
  statement: >-
    `SpecLedEx.Index.build/2` shall run the CrossField validator over every
    parsed ADR against the index built from the same tree, so the cross-field
    rules gate `mix spec.check` rather than only their own unit tests.
    Error-severity results shall be threaded into the decision's
    `parse_errors`; warning-severity results shall be threaded into a separate
    `parse_warnings` list and reported by the verifier as
    `decision_cross_field_warning` findings at `info` severity by default,
    because `mix spec.check` validates with `strict: true` where a warning
    fails the gate and legacy ADRs must keep parsing. Id resolution shall read
    both string-keyed index maps and atom-keyed schema structs, and shall
    accept subject ids, requirement ids, scenario ids, and decision ids.
  priority: must
  stability: evolving
- id: specled.decisions.cross_field_idempotent
  statement: >-
    `SpecLedEx.DecisionParser.CrossField.validate/3` shall be pure and
    idempotent: repeated invocation with byte-identical inputs shall
    return byte-identical output, and running the validator twice on
    the same inputs shall produce the same error set as running it
    once.
  priority: must
  stability: stable
- id: specled.decisions.adr_reference_discipline
  statement: >-
    Repository comment hygiene shall scan contiguous line-comment blocks of
    at least eight non-separator lines in `lib/specled_ex/realization/*.ex`,
    excluding comment-only hyphen separators from the line count; each block
    shall end with the id of an ADR that exists in `.spec/decisions/*.md`,
    except for blocks whose final line is a reason-bearing
    `# spec-lint:allow-long-comment=<reason>` marker. The marker is block-local
    and shall be honored only within that fixed realization corpus; section
    banners, numbered walkthroughs, and algorithm prose receive no implicit
    exemption.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.decisions.scenario.cross_field_live_gate
  given:
    - "a workspace whose ADR carries a weakening-set `change_type` and no `reverses_what:`"
    - "a workspace whose ADR affects a subject id that exists in the same tree"
    - "a workspace whose ADR carries no `change_type:` at all"
  when:
    - Index.build/2 parses the workspace and the verifier runs over the result
  then:
    - "the reverses_what violation reaches the verifier as an error-severity finding"
    - "the resolvable affect produces no `cross_field/affects_unresolved` entry"
    - "the missing change_type reaches the verifier as a `decision_cross_field_warning` finding at info severity, not as a parse error"
  covers:
    - specled.decisions.cross_field_live_gate
- id: specled.decisions.scenario.adr_reference_discipline
  given:
    - an eight-line realization comment block with no terminal ADR id
    - realization comment blocks ending in an existing ADR id or a reason-bearing opt-out marker
    - a section banner with fewer than eight prose-interior lines
    - a section banner with at least eight prose-interior lines
    - a realization comment block ending in an unknown ADR id
    - a numbered walkthrough with neither a terminal ADR id nor an opt-out marker
    - a reason-bearing opt-out marker on a path outside the realization corpus
  when:
    - the realization comment-pointer lint evaluates the blocks
  then:
    - the unpointed block, unknown ADR id, long-prose banner, and unmarked numbered walkthrough are rejected
    - the existing terminal ADR id, scoped opt-out marker, and short-prose banner are accepted
    - the marker outside the realization corpus grants no exemption
  covers:
    - specled.decisions.adr_reference_discipline
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.decisions.frontmatter_contract
    - specled.decisions.reference_validation
    - specled.decisions.change_type_enum
    - specled.decisions.weakening_set
    - specled.decisions.change_type_optional
    - specled.decisions.cross_field_supersedes_replaces
    - specled.decisions.cross_field_reverses_what
    - specled.decisions.cross_field_affects_non_empty
    - specled.decisions.cross_field_affects_resolve
    - specled.decisions.cross_field_adr_append_only
    - specled.decisions.cross_field_idempotent
    - specled.decisions.cross_field_live_gate
    - specled.decisions.adr_reference_discipline
- kind: source_file
  target: lib/specled_ex/decision_parser/cross_field.ex
  execute: true
  covers:
    - specled.decisions.cross_field_supersedes_replaces
    - specled.decisions.cross_field_reverses_what
    - specled.decisions.cross_field_affects_non_empty
    - specled.decisions.cross_field_affects_resolve
    - specled.decisions.cross_field_adr_append_only
    - specled.decisions.cross_field_idempotent
- kind: source_file
  target: lib/specled_ex/schema/decision.ex
  execute: true
  covers:
    - specled.decisions.change_type_enum
    - specled.decisions.weakening_set
```
