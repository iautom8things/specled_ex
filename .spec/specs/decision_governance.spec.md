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
  - lib/specled_ex/schema/decision.ex
  - lib/specled_ex/verifier.ex
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.change_type_enum_v1
  - specled.decision.adr_append_only
```

## Requirements

```yaml spec-requirements
- id: specled.decisions.frontmatter_contract
  statement: ADR files shall require YAML frontmatter with id, status, date, and affects plus Context, Decision, and Consequences sections.
  priority: must
  stability: stable
- id: specled.decisions.reference_validation
  statement: The verifier shall reject ADR affects or supersession links that do not resolve and shall warn when a subject references an unknown ADR id.
  priority: must
  stability: evolving
- id: specled.decisions.change_type_enum
  statement: >-
    ADR frontmatter shall accept an optional `change_type:` field whose
    value is one of `deprecates`, `weakens`, `narrows-scope`,
    `adds-exception`, `supersedes`, `clarifies`, or `refines`; values
    outside this set shall be rejected at schema parse.
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
    is being removed).
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
- id: specled.decisions.cross_field_idempotent
  statement: >-
    `SpecLedEx.DecisionParser.CrossField.validate/3` shall be pure and
    idempotent: repeated invocation with byte-identical inputs shall
    return byte-identical output, and running the validator twice on
    the same inputs shall produce the same error set as running it
    once.
  priority: must
  stability: stable
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/decision_parser_test.exs test/specled_ex/decision_parser/cross_field_test.exs test/specled_ex/verifier_test.exs
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
