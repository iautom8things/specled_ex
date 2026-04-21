# Block Schema

Zoi-backed contracts for authored Spec Led Development blocks.

## Intent

Define the structured shape of authored `spec-meta`, `spec-requirements`,
`spec-scenarios`, `spec-verification`, and `spec-exceptions` blocks.

```spec-meta
id: specled.block_schema
kind: contract
status: active
summary: Validates authored block payloads into Zoi-backed structs with precise validation errors.
surface:
  - lib/specled_ex/schema.ex
  - lib/specled_ex/schema/meta.ex
  - lib/specled_ex/schema/requirement.ex
  - lib/specled_ex/schema/scenario.ex
  - lib/specled_ex/schema/verification.ex
  - lib/specled_ex/schema/exception.ex
decisions:
  - specled.decision.explicit_subject_ownership
```

## Requirements

```spec-requirements
- id: specled.schema.meta_contract
  statement: The `spec-meta` contract shall accept stable ids, kind, status, optional summary and surface, optional ADR references, and optional verification minimum strength.
  priority: must
  stability: stable
- id: specled.schema.block_structs
  statement: Requirements, scenarios, verifications, and exceptions shall validate into Zoi-backed structs with the expected required fields.
  priority: must
  stability: stable
- id: specled.schema.validation_errors
  statement: Block validation shall reject invalid ids, invalid verification kinds or strengths, and malformed list items with indexed error messages.
  priority: must
  stability: stable
- id: specled.schema.tagged_tests_kind
  statement: The `spec-verification` contract shall accept `tagged_tests` as a verification kind and allow `target` to be omitted, since tagged_tests verifications derive their test set from the `@tag spec:` index.
  priority: must
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/schema_test.exs test/specled_ex/parser_test.exs
  execute: true
  covers:
    - specled.schema.meta_contract
    - specled.schema.block_structs
    - specled.schema.validation_errors
    - specled.schema.tagged_tests_kind
```
