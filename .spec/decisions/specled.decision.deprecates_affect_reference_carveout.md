---
id: specled.decision.deprecates_affect_reference_carveout
status: accepted
date: 2026-07-25
affects:
  - specled.decisions.reference_validation
change_type: narrows-scope
reverses_what: >-
  `specled.decisions.reference_validation` previously stated that all ADR
  affects links must resolve, but deprecation ADRs need to name ids that have
  been removed from the current index.
---

# Deprecation ADRs May Reference Retired Affects Targets

## Context

`specled.decisions.reference_validation` historically stated one broad rule:
ADR `affects:` links and supersession links must resolve. Later CrossField
policy added a specific deprecation rule: `change_type: deprecates` may list
an `affects:` id that is absent from the current index, because the purpose of
the ADR is to explain that the target is being removed.

Without a current-truth carve-out, the general verifier requirement says
something stricter than both CrossField and the live verifier now enforce.
That makes the spec false for deprecation ADRs.

## Decision

Narrow reference validation with one explicit exception:
`change_type: deprecates` ADRs may list `affects:` ids that do not resolve in
the current index. All other ADR `affects:` links still must resolve, and ADR
supersession links still must resolve.

The exemption stays deprecates-only. The append-only weakening set
(`deprecates`, `weakens`, `narrows-scope`, `adds-exception`) authorizes prior
spec weakening, but only `deprecates` implies that the affected id may no
longer exist. `weakens`, `narrows-scope`, and `adds-exception` alter an
existing requirement or subject; requiring their `affects:` targets to resolve
keeps the review trail tied to the current spec surface.

## Consequences

- **Positive:** The current-truth requirement matches CrossField and verifier
  behavior for deprecation ADRs.
- **Positive:** Non-deprecation weakening ADRs still have to point at a live
  subject or requirement id, preserving mechanical reviewability.
- **Negative:** ADR authors must choose `change_type: deprecates` when the
  target id has already left the current index; other weakening labels remain
  stricter.

## Related

- `specled.decision.change_type_enum_v1` — defines the weakening set and the
  meaning of `deprecates`.
- `specled.decision.adr_append_only` — requires a new ADR for this weakening
  rather than silently rewriting the prior requirement.
