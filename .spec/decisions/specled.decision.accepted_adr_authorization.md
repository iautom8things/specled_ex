---
id: specled.decision.accepted_adr_authorization
status: accepted
date: 2026-08-12
affects:
  - specled.append_only
change_type: clarifies
---

# Only Accepted ADRs Authorize Append-Only Weakenings

## Context

AppendOnly permits a head-side ADR in the weakening set to authorize requirement
deletion, modal downgrade, scenario regression, or negative-polarity removal.
The authorization lookup historically considered `change_type` and `affects`
but ignored ADR status. As a result, a `deprecated` or `superseded` ADR could
continue authorizing new weakenings indefinitely.

Those two statuses are terminal historical states under
`specled.decision.adr_append_only`. They retain the rationale for a decision
that no longer governs current behavior. Treating either as active authority
would allow a retired exception to suppress a new append-only violation.

## Decision

Only a head-side ADR whose status is `accepted` may authorize an AppendOnly
weakening. The rule applies uniformly to all four weakening detectors and to
both self-authorization surfaces:

- `deprecated` and `superseded` ADRs do not suppress weakening findings;
- inactive ADRs do not emit `append_only/same_pr_self_authorization`; and
- inactive ADRs do not emit `append_only/self_authorized_weakening` markers.

The legal status enum remains `accepted | deprecated | superseded`. This
decision does not add a `rejected` status or change the schema.

## Consequences

- Retiring an ADR also retires its authority over future weakenings while
  preserving its historical record.
- Authorization selection remains order-independent among accepted ADRs under
  `specled.decision.uniform_self_authorization_markers`.
- A weakening previously covered only by an inactive ADR now emits its normal
  class-specific error and requires a new accepted ADR to proceed.

## Related

- `specled.decision.adr_append_only` defines forward-only status transitions.
- `specled.decision.change_type_enum_v1` defines the weakening set.
- `specled.decision.uniform_self_authorization_markers` defines authorizer
  selection after status eligibility is established.
