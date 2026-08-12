---
id: specled.decision.uniform_self_authorization_markers
status: accepted
date: 2026-08-12
affects:
  - specled.append_only
change_type: clarifies
---

# Self-Authorization Markers Use One Order-Independent Authorization Rule

## Context

AppendOnly suppresses four weakening classes when a head-side ADR authorizes
the affected requirement. It also emits an informational marker when that ADR
is new in the current diff. The implementation previously chose the first
authorizing ADR for modal downgrades, scenario regressions, and polarity
removals, but used a last-write-wins map for a deletion fast path.

Those paths left two observable questions unanswered. A pre-existing ADR could
mask a new ADR solely because it appeared first in the decision list, and two
new ADRs could name different authorizers depending on their input order. The
subject contract also did not state whether multiple authorizers or multiple
weakening classes produced one marker or several.

## Decision

AppendOnly emits exactly one `append_only/self_authorized_weakening` marker per
`(requirement id, weakening class)` pair. A requirement weakened in two classes
therefore emits two markers; multiple ADRs authorizing one class do not multiply
that class's marker.

All four weakening detectors use the same authorizing-decision selection rule:

1. Consider every head-side ADR whose `affects` includes the requirement and
   whose `change_type` belongs to the weakening set.
2. Prefer new-in-diff ADRs over ADRs already present at base. This keeps a
   same-diff self-authorization visible even when an older ADR also authorizes
   the requirement.
3. Within the same newness class, select the lexicographically smallest ADR id.

The selection is independent of decision input order. The separate
`append_only/same_pr_self_authorization` warning remains per qualifying new ADR;
this decision changes only the per-weakening marker and its authorization
selection.

The deletion fast path is replaced by this shared selection rule. Superset
`affects` deletion remains covered because every authorizing ADR is considered,
whether or not its full affects set qualifies for the per-ADR same-PR warning.

## Consequences

- Marker cardinality and attribution are deterministic for downstream reports
  and snapshot tests.
- A redundant new authorizer is visible instead of being hidden by an older
  authorizer.
- Lexicographic ADR ids are a policy tie-break, not a chronology signal; review
  still decides whether the selected self-authorization is legitimate.
- Authorization status filtering remains unchanged and is intentionally left
  to the follow-up decision governing superseded or rejected ADRs.
