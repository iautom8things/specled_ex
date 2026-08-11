---
id: specled.decision.amplification_scoped_dedupe
status: accepted
date: 2026-08-11
change_type: narrows-scope
affects:
  - specled.realized_by
  - specled.api_boundary
---

# api_boundary Dedupe Is Amplification-Scoped; Authored Bindings Are Never Collapsed by MFA

## Context

`collect_bindings/2` deduplicated the api_boundary tier's flat binding list
on MFA alone (`Enum.uniq_by(& &1.mfa)`, first-seen wins), with stable
subject-before-requirement ordering. The dedupe exists for one reason: the
`implementation ⟹ api_boundary` implication injects the same MFA at both
the subject and requirement layers, and without dedupe one code change
produced duplicate drift findings.

Two defects rode in on the whole-list key (builder-912):

1. **The shadow.** A subject-level INFERRED entry preceded authored
   requirement entries, so the authored ones were discarded. Because the
   api_boundary detector suppresses dangling findings for inferred entries
   (deferring to the `:implementation` tier, which is excluded from the
   default tier set), a nonexistent authored MFA produced ZERO findings.
   Measured in the reporting adopter: 381 requirement-level bindings
   shadowed across 31 of 48 subjects; a binding on a function that does not
   exist survived a full `Orchestrator.run` silently.
2. **The cross-requirement collapse.** Independent requirements binding the
   same MFA collapsed to one entry (the adopter measured 594 distinct MFAs,
   439 declared more than once, 64 spanning multiple subject files), so all
   but one requirement silently lost their binding — and every surviving
   finding reported `requirement_id: nil`, the subject-layer entry's
   attribution.

The single-key design was deliberate — the code's own comment justified NOT
deduping other tiers because "drift findings on the same MFA from
independent requirement_ids still convey distinct provenance." That is
precisely the argument against the api_boundary collapse: the philosophy
was already correct, and the api_boundary tier was its one violation.

## Decision

Deduplication is scoped to what the amplification actually creates:

- **Authored entries are never collapsed by MFA.** Only exact
  `{subject_id, requirement_id, mfa}` duplicates drop. Independent
  requirements binding one function each keep a live entry and their own
  finding attribution.
- **Inferred entries dedupe on MFA among themselves** (the original
  amplification case: subject-layer and requirement-layer implementation
  lists injecting the same MFA), **and yield entirely to any authored entry
  sharing their MFA.** Authored beats inferred; the inferred entry's
  dangling suppression can no longer extend to an authored declaration.

## Consequences

- A nonexistent authored MFA emits `branch_guard_dangling_binding` with
  requirement-level attribution even when the subject's implementation list
  names the same MFA. The 381-binding silent class is closed.
- Drift on an MFA bound by N requirements emits N findings, one per
  requirement, UNGROUPED — the multiplicity the other tiers always had.
  Nothing collapses them downstream: `Drift.dedupe/2` serves the `:use`
  tier only and groups by subject, not MFA. Adopters should expect N-fold
  finding volume on multi-requirement MFAs (the reporting adopter measured
  439 MFAs declared more than once, 64 spanning subjects). The same applies
  cross-layer: a subject-level authored entry and a requirement-level
  authored entry for one MFA are distinct keys and both report.
- Previously-shadowed requirements now populate their clean-MFA attestation
  buckets, so tagged-tests test-file attestations appear where they did not
  before — file-touch attested/unattested partitions can move on the
  adopter's corpus sweep.
- No baseline change: `.spec/realization_hashes.json` is keyed by MFA, so
  entry count and hash values are unchanged; the hashing path dedupes to
  one resolution per distinct MFA before computing (the detector keeps the
  multiplicity).
- Adopters whose corpora carry shadowed dangling bindings will see NEW
  dangling findings on upgrade. That is the defect surfacing, not a
  regression — plan the corpus sweep as a deliberate exercise (the
  reporting adopter's recipe lives on builder-912).
