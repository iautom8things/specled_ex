---
id: specled.decision.append_only_finding_budget_v3
status: accepted
date: 2026-08-12
affects:
  - specled.append_only
  - specled.overlap
change_type: supersedes
replaces:
  - specled.decision.append_only_finding_budget_v2
reverses_what: >-
  Supersedes the thirteen-code append-only and overlap budget to admit a
  warning for must-priority requirements whose statement changes in place
  while the stable requirement id otherwise evades append-only weakening
  detection.
---

# Append-Only + Overlap Finding-Code Budget v3: Fourteen Ratified Codes

## Context

`specled.decision.append_only_finding_budget_v2` ratified eleven
`append_only/*` codes and two `overlap/*` codes. Its detectors cover deletion,
modal downgrade, scenario regression, polarity loss, and governance failures,
but none distinguishes a must-priority requirement whose id remains stable
while its statement is rewritten in place.

That gap is not hypothetical: a legitimate correction can replace an
implementation-prescriptive statement while keeping its id, priority, and
scenario coverage. The existing gate cannot surface that change for explicit
review. Persisting statement digests is unnecessary because append-only
analysis already reconstructs both base and head states and compares them in
memory.

## Decision

### Ratified codes (12 append_only + 2 overlap)

| Code | Default severity | Entity shape | Rule |
|---|---|---|---|
| `append_only/requirement_deleted` | `:error` | requirement id | R1.a + B1 subject scope |
| `append_only/must_downgraded` | `:error` | requirement id | R1.b via ModalClass |
| `append_only/statement_rewritten` | `:warning` | requirement id | must-priority text changed after whitespace normalization |
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
  `negative_removed` remain the four error-level shapes of silent weakening;
  their remediation restores prior contract strength or authorizes weakening.
- `statement_rewritten` is a distinct failure shape rather than a new emission
  surface. It compares requirement statements already present in the base and
  head payloads used by the existing append-only analysis. Its remediation is
  different: review whether the rewrite is legitimate, restore accidental
  text, or record clarification rationale. It is a warning because changed
  prose may clarify or strengthen the contract and therefore must not gate.
- Reusing one of the four weakening codes would violate one-code,
  one-severity, one-entity-shape discipline: those codes are errors with
  weakening-specific restoration or authorization, while this code is an
  advisory warning keyed to the requirement id and asks for rewrite review.
- `disabled_without_reason`, `no_baseline`, `adr_affects_widened`,
  `same_pr_self_authorization`, `self_authorized_weakening`,
  `missing_change_type`, `decision_deleted`, and both `overlap/*` codes retain
  the severity, entity shape, and remediation ratified by v2.

The counting rule from `specled.decision.finding_code_budget` applies here:
"fourteenth" counts entries in this ADR's ratified table, not codes emitted
across the repository. This ADR deliberately does not restate a repo-wide
total. The v2 total used seven branch-guard codes while the branch-guard ADR's
Decision list now carries ten slots, so repeating or arithmetically extending
that total would preserve a known inconsistency rather than reconcile it.

### Comparison rule

For a requirement present on both sides, compare its statement only when its
priority is `must` in both base and head. Normalize all whitespace runs before
comparison so formatting and YAML folding changes remain silent. A differing
normalized statement emits one `append_only/statement_rewritten` warning with
the requirement id as its entity. No digest or migration state is persisted.

## Consequences

- **Positive:** stable-id contract rewrites become visible during branch
  review even when deletion, modal, scenario, and polarity detectors are quiet.
- **Positive:** first-run behavior and base reconstruction are unchanged; no
  baseline migration is required.
- **Positive:** formatting-only reflow does not create noise.
- **Negative:** legitimate clarifications and strengthening rewrites emit an
  advisory warning that reviewers must resolve by judgment.
- **Negative:** the public append-only finding surface grows by one code, from
  eleven to twelve codes; the combined append-only and overlap axis grows from
  thirteen to fourteen entries.
