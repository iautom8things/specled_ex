---
id: specled.decision.append_only_finding_budget_v2
status: accepted
date: 2026-08-06
affects:
  - specled.append_only
  - specled.overlap
change_type: supersedes
replaces:
  - specled.decision.append_only_finding_budget
reverses_what: >-
  Supersedes the twelve-code append-only and overlap budget to admit an
  informational per-requirement marker for weakening authorized by an ADR
  authored in the same diff, and extends same-PR warning matching from exact
  removed-id equality to a non-empty subset of all weakened requirement ids.
---

# Append-Only + Overlap Finding-Code Budget v2: Thirteen Ratified Codes

## Context

`specled.decision.append_only_finding_budget` ratified ten `append_only/*`
codes and two `overlap/*` codes. It assigned one severity and one entity shape
to each code so configuration overrides and remediation remain unambiguous.

The original same-PR warning detected only a new ADR whose `affects` set exactly
matched the requirements deleted in that diff. Scenario regressions, modal
downgrades, and polarity removals could therefore be self-authorized without
any visibility. A new ADR with a superset `affects` list also suppressed a
weakening without either the exact-match warning or a requirement-level trace.

Reusing `append_only/same_pr_self_authorization` for both warning-level ADR
findings and info-level requirement findings would violate the one-code,
one-severity, one-entity-shape discipline. This ADR supersedes the prior budget
and admits a distinct informational marker.

## Decision

### Ratified codes (11 append_only + 2 overlap)

| Code | Default severity | Entity shape | Rule |
|---|---|---|---|
| `append_only/requirement_deleted` | `:error` | requirement id | R1.a + B1 subject scope |
| `append_only/must_downgraded` | `:error` | requirement id | R1.b via ModalClass |
| `append_only/scenario_regression` | `:error` | requirement id | R1.c count-based |
| `append_only/negative_removed` | `:error` | requirement id | R1.d polarity loss |
| `append_only/disabled_without_reason` | `:warning` | scenario id | R1.e head-only |
| `append_only/no_baseline` | `:info` | none | bootstrap / shallow-clone (C11) |
| `append_only/adr_affects_widened` | `:error` | ADR id | C5 immutability |
| `append_only/same_pr_self_authorization` | `:warning` | ADR id | C3 per-ADR visibility |
| `append_only/self_authorized_weakening` | `:info` | requirement id | C3 per-weakening visibility |
| `append_only/missing_change_type` | `:warning` | ADR id | C8 warning-level optionality |
| `append_only/decision_deleted` | `:error` | ADR id | ADR append-only directive |
| `overlap/duplicate_covers` | `:error` | requirement id | R4 scenario-level |
| `overlap/must_stem_collision` | `:error` | requirement id | R4 requirement-level |

### Per-code justification

- `requirement_deleted`, `must_downgraded`, `scenario_regression`, and
  `negative_removed` are the four distinct shapes of silent spec weakening.
  Their error findings retain distinct remediation details.
- `disabled_without_reason` records an authored but unexplained disabled
  scenario. It remains a warning because disabling is explicit rather than
  silent.
- `no_baseline` is informational because a missing comparison base cannot be
  repaired as a head-side behavioral violation.
- `adr_affects_widened` protects structural immutability of accepted ADRs and
  directs authors to supersede rather than edit history.
- `same_pr_self_authorization` is the warning-level, ADR-shaped C3 finding. It
  tells reviewers that every requirement named by a new weakening ADR was
  weakened in the same diff.
- `self_authorized_weakening` is the new info-level, requirement-shaped C3
  marker. It identifies each suppressed deletion, scenario regression, modal
  downgrade, or polarity removal authorized by a new-in-diff ADR, including
  suppressions by a superset `affects` list that do not qualify for the ADR
  warning. Its distinct entity and severity justify a distinct code.
- `missing_change_type` preserves warning-level v1 compatibility for a
  consulted ADR without classification.
- `decision_deleted` is the ADR-file analog of requirement deletion and has a
  different restore/status-transition remediation.
- `overlap/duplicate_covers` and `overlap/must_stem_collision` retain their
  separate scenario-level and requirement-level remediation shapes.

### Same-PR matching extension

The warning match changes from equality between a new ADR's `affects` set and
the removed-id set to this rule: `affects` must be non-empty and must be a
subset of the requirement ids weakened in the diff. The weakened-id set is the
union of removed, scenario-count-regressed, modal-downgraded, and
negative-polarity-stripped ids.

This is a pure extension of the prior requirement: every exact removed-id match
is also a non-empty subset of the weakened-id union. The clauses that the ADR
must be new in the current diff, the finding severity is `:warning`, and the
pattern is visible without blocking all remain unchanged. Matching remains at
requirement-id granularity; subject-prefix matching is not permitted.

A new ADR whose `affects` set includes an untouched id does not emit the
per-ADR warning. Any weakening that ADR actually suppresses still emits the
per-requirement info marker. An ADR already present at base emits neither
self-authorization finding.

### Cap revision

`specled.decision.finding_code_budget`'s seven-code cap remains scoped to the
branch-guard slice. This axis now ratifies thirteen codes, bringing the total
specled_ex finding-code budget to 24: seven branch-guard, four tag-finding, and
thirteen append-only/overlap codes. Any future addition to this axis must
justify itself in another supersedes-style ADR.

## Consequences

- **Positive:** every suppressed weakening authorized by a same-diff ADR is
  visible at requirement granularity, even when the ADR has a wider affects
  list.
- **Positive:** the existing warning now covers all four weakening classes,
  while every previously firing deletion case continues to fire.
- **Positive:** severity overrides remain deterministic because the ADR warning
  and requirement marker use distinct finding codes.
- **Negative:** the public finding-code surface grows by one. The marker shares
  the established fix-block discipline, so its remediation is available in the
  emitted message.
- **Negative:** the detectors must retain consulted weakened ids even when an
  ADR suppresses the error. This is accepted as part of the detector tuple
  contract and is covered by per-class tests.
- **Behavioral:** the deletion detector's self-authorization branch now also
  feeds `consulted_ids`, which widens `append_only/missing_change_type` reach:
  a decision without a `change_type` whose `affects` names a requirement whose
  deletion was suppressed by a same-diff self-authorizing ADR is now flagged.
  Deliberate — marker paths keep putting ids into consulted sets.
