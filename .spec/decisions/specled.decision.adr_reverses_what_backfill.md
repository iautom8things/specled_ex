---
id: specled.decision.adr_reverses_what_backfill
status: accepted
date: 2026-08-14
affects:
  - specled.append_only.adr_affects_widened
change_type: adds-exception
reverses_what: >-
  `specled.append_only.adr_affects_widened` previously treated every
  `reverses_what:` difference on an accepted ADR as structural drift; adding a
  value where base had none is now exempt, so an ADR authored before the
  cross-field contract was enforced can be repaired without being superseded.
---

# Backfilling an Absent `reverses_what:` Is Not ADR Drift

## Context

`specled.decisions.cross_field_reverses_what` requires every ADR with a
weakening-set `change_type` to carry a non-blank `reverses_what:`. That rule
lived in `SpecLedEx.DecisionParser.CrossField` with no production caller until
`specled.decisions.cross_field_live_gate` put it on the live decision-parse
path, so ADRs authored while it was unenforced were never checked.

Four accepted ADRs in this repository declare a weakening-set `change_type`
with no `reverses_what:` at all
(`specled.decision.amplification_scoped_dedupe`,
`specled.decision.doc_identifier_lint_spec_corpus`,
`specled.decision.parser_resilient_errors_split`,
`specled.decision.resolution_path_provenance`). Activating the gate makes each
one a hard error.

They could not be repaired. `SpecLedEx.AppendOnly.analyze/4` compared
`reverses_what` verbatim between base and head and emitted
`append_only/adr_affects_widened` at `:error` for any difference, so adding the
missing prose turned the branch guard red. The only remaining remedy was
superseding four records whose decisions are correct and current — pure
ceremony that grows the corpus and teaches the wrong lesson. Every adopter
upgrading into the live gate faces the same wall for their own pre-contract
ADRs.

## Decision

A `reverses_what:` that is absent or blank (after `String.trim/1`) at base and
non-blank at head is not drift. `append_only/adr_affects_widened` does not fire
for it.

The exception is deliberately narrow:

- `change_type` and `affects` are still compared verbatim. What an accepted ADR
  *authorizes* is fixed by those two fields, and neither may move.
- Blank → non-blank only. Editing a `reverses_what` that was already non-blank
  at base is still drift, and so is deleting one.

Immutability protects against retroactive re-authorization: rewriting an ADR so
it appears to have permitted a weakening it never permitted. Supplying missing
justification prose for a `change_type` that has not moved cannot do that.

## Consequences

- **Positive:** The four pre-contract ADRs are repairable in place, and
  adopters get the same legal repair instead of forced supersession.
- **Positive:** The immutability guarantee that matters — `change_type` and
  `affects` — is unchanged, so no weakening can be retroactively authorized.
- **Negative:** An author who omits `reverses_what` in the PR that introduces
  an ADR may add it later without the diff being flagged as ADR drift. The live
  cross-field gate rejects the ADR at error severity while the field is
  missing, so the window is bounded by that gate rather than by this detector.
- **Negative:** Base-side blankness is now load-bearing, so the detector reads
  two shapes of the same field (absent key and empty string) where it
  previously read one.

## Related

- `specled.decision.adr_append_only` — establishes accepted-ADR immutability;
  this ADR carves the backfill case out of it.
- `specled.decision.live_cross_field_gate` — activates the rule that makes the
  backfill necessary.
- `specled.decision.change_type_enum_v1` — defines `adds-exception` in the
  weakening set that authorizes this exception.
