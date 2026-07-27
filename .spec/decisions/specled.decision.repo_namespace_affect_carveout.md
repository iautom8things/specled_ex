---
id: specled.decision.repo_namespace_affect_carveout
status: accepted
date: 2026-07-27
affects:
  - specled.decisions.reference_validation
  - specled.decisions.cross_field_affects_resolve
change_type: adds-exception
reverses_what: >-
  `specled.decisions.reference_validation` and
  `specled.decisions.cross_field_affects_resolve` previously required every
  non-deprecates ADR `affects:` id to resolve in the current index; the
  reserved `repo.` prefix namespace is intentionally unindexed and must be
  accepted without resolution.
---

# Reserved `repo.` Affect Prefix Is Accepted Without Index Resolution

## Context

`SpecLedEx.Verifier.valid_decision_affect?/4` already accepts any ADR
`affects:` id with a literal `String.starts_with?(affect, "repo.")` prefix
test, without resolving it against subjects, requirements, or ADR ids. The
namespace names repo-level policy areas (for example `repo.governance`) that
are not, and never will be, entries in the subject/requirement/decision index.

`specled.decisions.reference_validation` and
`specled.decisions.cross_field_affects_resolve` still stated a narrower
current truth: only `change_type: deprecates` was an exception to resolution.
`specled.decision.deprecates_affect_reference_carveout` further said that
"All other ADR `affects:` links still must resolve," which is false for the
live verifier's `repo.` branch and would become false for CrossField R4 once
that path is wired into the live decision-parse gate.

Without a documented exception, the requirements over-claim and CrossField
R4 would reject every committed ADR that carries `- repo.governance` as soon
as it is activated on the live path.

## Decision

Add a second explicit exception to reference validation and to CrossField
affects-resolution:

- ADR `affects:` ids in the reserved `repo.` prefix namespace are repo-scoped
  governance identifiers. They are not spec subjects, requirements, or ADR
  ids.
- They intentionally resolve against nothing in the index and are accepted
  without resolution.
- Acceptance is a literal `String.starts_with?/2` prefix test (`"repo."`),
  not a registry lookup and not a membership check against any known set of
  policy area names.

This supersedes the sentence in
`specled.decision.deprecates_affect_reference_carveout` that "All other ADR
`affects:` links still must resolve." That sentence remains true for ids
outside the `repo.` prefix (and outside the deprecates carve-out); it is
false for `repo.*` affects and is replaced by the rule above.

The deprecates carve-out is unchanged: `change_type: deprecates` still
exempts its entire `affects:` list. The `repo.` exemption is independent of
`change_type` and applies only to ids that pass the prefix test.

## Consequences

- **Positive:** The current-truth requirements match the live verifier and
  CrossField R4 for the `repo.` namespace already used by committed ADRs.
- **Positive:** Wiring CrossField into the live decision-parse path no longer
  red-gates the corpus on every `- repo.governance` affect.
- **Positive:** Non-`repo.` unresolvable affects still fail both the verifier
  and CrossField, so the resolution check is not disabled wholesale.
- **Negative:** Authors can invent any `repo.*` string without registry
  validation; governance of those labels remains a human convention, not a
  mechanical catalog.

## Related

- `specled.decision.deprecates_affect_reference_carveout` — prior carve-out
  for `change_type: deprecates`; its "all other affects must resolve"
  sentence is superseded for the `repo.` prefix by this ADR.
- `specled.decision.adr_append_only` — requires a new ADR for this exception
  rather than silently rewriting the prior requirement.
- `specled.decision.change_type_enum_v1` — defines `adds-exception` in the
  weakening set that authorizes this AppendOnly exception.
