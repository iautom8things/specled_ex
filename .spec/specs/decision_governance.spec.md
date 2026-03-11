# Decision Governance

ADR parsing and validation rules for durable cross-cutting decisions.

## Intent

Define how `.spec/decisions/*.md` files are structured and how subject specs connect to them.

```spec-meta
id: specled.decisions
kind: workflow
status: active
summary: Parses ADRs, validates their contract, and lets subject specs reference durable cross-cutting decisions.
surface:
  - lib/specled_ex/decision_parser.ex
  - lib/specled_ex/schema/decision.ex
  - lib/specled_ex/verifier.ex
decisions:
  - specled.decision.declarative_current_truth
```

## Requirements

```spec-requirements
- id: specled.decisions.frontmatter_contract
  statement: ADR files shall require YAML frontmatter with id, status, date, and affects plus Context, Decision, and Consequences sections.
  priority: must
  stability: stable
- id: specled.decisions.reference_validation
  statement: The verifier shall reject ADR affects or supersession links that do not resolve and shall warn when a subject references an unknown ADR id.
  priority: must
  stability: evolving
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/decision_parser_test.exs test/specled_ex/verifier_test.exs
  execute: true
  covers:
    - specled.decisions.frontmatter_contract
    - specled.decisions.reference_validation
```
