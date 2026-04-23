---
id: specled.decision.append_only_finding_budget
status: accepted
date: 2026-04-23
affects:
  - specled.append_only
  - specled.overlap
change_type: adds-exception
reverses_what: >-
  Lifts the v1 finding-code cap set by specled.decision.finding_code_budget
  (which held the branch_guard slice to seven new codes) to admit the ten
  append_only/* codes and two overlap/* codes that the spec-guardrails
  feature requires.
---

# Append-Only + Overlap Finding-Code Budget: Twelve Ratified Codes

## Context

`specled.decision.finding_code_budget` caps the v1 addition of new
branch_guard finding codes at seven, with the policy that any new code
must justify itself against the budget. The spec-guardrails feature
(epic specled_-fm4) adds a new detector axis — state-based append-only
validation plus head-only semantic overlap rejection — that cannot be
expressed inside the seven branch_guard codes without overloading their
semantics.

Appendix B of the refined plan (2026-04-22 run, refined 2026-04-23 after
the user directive to make ADRs append-only) enumerates twelve new codes.
Each maps to a distinct failure mode with a distinct remediation
instruction. Collapsing any two would force the remediation message to
branch at emission time, which is exactly what the "one code per fix
shape" discipline in `finding_code_budget` exists to prevent.

Twelve is more than seven. This ADR explicitly lifts the cap for this
feature. Total specled_ex finding-code count after merge: 7 branch_guard
+ 4 tag_findings + 12 new = 23.

## Decision

### Ratified codes (10 append_only + 2 overlap)

| Code | Default severity | Source | Rule |
|---|---|---|---|
| `append_only/requirement_deleted` | `:error` | AppendOnly | R1.a + B1 subject scope |
| `append_only/must_downgraded` | `:error` | AppendOnly | R1.b via ModalClass |
| `append_only/scenario_regression` | `:error` | AppendOnly | R1.c count-based |
| `append_only/negative_removed` | `:error` | AppendOnly | R1.d polarity loss |
| `append_only/disabled_without_reason` | `:warning` | AppendOnly | R1.e head-only |
| `append_only/no_baseline` | `:info` | AppendOnly | bootstrap / shallow-clone (C11) |
| `append_only/adr_affects_widened` | `:error` | AppendOnly | C5 immutability |
| `append_only/same_pr_self_authorization` | `:warning` | AppendOnly | C3 visibility |
| `append_only/missing_change_type` | `:warning` | AppendOnly | C8 warning-level optionality |
| `append_only/decision_deleted` | `:error` | AppendOnly | ADR append-only (2026-04-23 directive) |
| `overlap/duplicate_covers` | `:error` | Overlap | R4 scenario-level |
| `overlap/must_stem_collision` | `:error` | Overlap | R4 requirement-level |

### Per-code justification

- `requirement_deleted`, `must_downgraded`, `scenario_regression`,
  `negative_removed` — the four shapes of silent spec weakening that the
  feature's whole premise rests on. Each has a distinct fix-block
  (ADR change_type name differs per rule).
- `disabled_without_reason` — head-only diagnostic; authors stub out a
  scenario and owe a `reason:` so the next reader knows why. Warning not
  error because the disable is itself an authored choice, not a silent
  weakening.
- `no_baseline` — informational marker for first-run and shallow-clone
  cases. Not an error because there is no base to compare against.
  `:info` severity lets projects keep it in logs without failing CI.
- `adr_affects_widened` — structural immutability on accepted ADRs.
  Distinct fix from `requirement_deleted` because the remediation is
  "author a new ADR", not "restore the requirement".
- `same_pr_self_authorization` — C3 visibility for the
  same-PR-authors-own-exception pattern. Warning only; review decides.
- `missing_change_type` — C8 warning-level optionality. Emitted only
  when the ADR is consulted by an authorization lookup.
- `decision_deleted` — the ADR-file analog of `requirement_deleted`.
  Distinct code because the remediation is "restore the file with
  appropriate status transition", not "restore the requirement id".
- `overlap/duplicate_covers` — two scenarios covering the same
  requirement. Fix is "delete one or re-scope".
- `overlap/must_stem_collision` — two MUST-priority requirements with
  the same canonicalized stem. Fix is "merge or differentiate".

### Cap revision

`specled.decision.finding_code_budget`'s seven-code cap stands for the
branch_guard slice. The total specled_ex cap is raised to 23 by this
ADR. Any future code addition beyond this list must justify against
this ADR (for `append_only/*` or `overlap/*`) or against the parent
budget (for other detector families) via a new supersedes-style ADR.

## Consequences

- **Positive:** every code has a one-shape fix. Messages carry the
  required `fix:` block per R1.f without branching.
- **Positive:** `config.severities` gets per-code defaults for each of
  the twelve; projects can promote `:warning` to `:error` or demote
  `:error` to `:warning` without touching detector code.
- **Positive:** the documentation surface grows by twelve but each code
  documents one failure shape, matching the finding_code_budget policy
  intent.
- **Negative:** 23 codes is more than a new user can memorize at a
  glance. Mitigated by the fix-block discipline — every emitted finding
  carries its own remediation.
- **Negative:** future additions to this axis must supersede this ADR
  rather than append to `finding_code_budget`. Acceptable: the
  branch_guard and append_only axes evolve independently.
