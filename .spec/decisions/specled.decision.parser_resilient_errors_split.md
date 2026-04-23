---
id: specled.decision.parser_resilient_errors_split
status: accepted
date: 2026-04-23
affects:
  - specled.parser
  - specled.parser.resilient_errors
change_type: narrows-scope
---

# Split `parser.resilient_errors` Into Per-Failure-Mode Sub-Requirements

## Context

`specled.parser.resilient_errors` was a single umbrella requirement covering
every structured-block failure mode the parser must survive (decode
failure, duplicate block, schema validation failure). Two scenarios
(`malformed_json`, `duplicate_empty_block`) both listed it in their
`covers:` field, tripping `overlap/duplicate_covers` after the Overlap
module was wired into BranchCheck.

The right structural fix is per-failure-mode sub-requirements, each
covered by one exemplar scenario. The umbrella stays as a group intent
statement (and is covered by a lightweight totality scenario plus the
verification target), but the specific failure-mode assertions now live
in distinct ids.

## Decision

Two new sub-requirements were authored beside the umbrella:

- `specled.parser.resilient_on_decode_error` — parser records a parse
  error and continues when a structured block contains malformed
  YAML/JSON that cannot be decoded. Covered by scenario
  `specled.parser.malformed_json`.
- `specled.parser.resilient_on_duplicate_block` — parser records a
  duplicate-block parse error and continues when the same structured
  block kind appears more than once. Covered by scenario
  `specled.parser.duplicate_empty_block`.

The two existing scenarios were retargeted from `resilient_errors` to
their respective sub-ids. A new `resilient_errors_totality` scenario was
added to keep the umbrella with a covering scenario; the verification
target in `parser.spec.md` also covers all three ids.

Net effect on umbrella `specled.parser.resilient_errors`:

- base: covered by 2 scenarios
- head: covered by 1 scenario (`resilient_errors_totality`) plus the
  verification target

This ADR authorizes the `append_only/scenario_regression` signal on
`specled.parser.resilient_errors` under `change_type: narrows-scope`.

## Consequences

- **Positive:** Each failure mode has a dedicated requirement id, so
  future scenarios naturally attach to the specific mode rather than
  re-covering the umbrella. Duplicate-covers on this requirement is
  closed by construction.
- **Positive:** The umbrella remains as a documentation anchor and a
  stable verification target, so external references (commit messages,
  test `@tag spec:` headers elsewhere) stay valid.
- **Negative:** Specs that grow a third structured-block failure mode
  will need a new sub-requirement + a new exemplar scenario rather than
  piggy-backing on an existing one. This is the intended cost.

## Related

- `specled.decision.adr_append_only` — why scope narrowings must be
  authorized rather than applied silently.
- `specled.decision.change_type_enum_v1` — definition of
  `narrows-scope` and its place in the weakening set.
