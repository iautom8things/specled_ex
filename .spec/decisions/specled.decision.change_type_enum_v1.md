---
id: specled.decision.change_type_enum_v1
status: accepted
date: 2026-04-23
affects:
  - specled.append_only
  - specled.decisions
---

# v1 `change_type` Enum: 7 Values, 4-Value Weakening Set, Optional With Warning

## Context

ADR governance needs a structured signal for *what kind of change* an ADR
authorizes relative to the requirement being modified. The refined plan's
red-team pass converged on a narrow enum (D2 "keep `refines`", D3 "drop
`adds`", D4 "keep `adds-exception` distinct from `weakens`"), a smaller
weakening set than the enum (AppendOnly exceptions cut narrower than the
full label space), and explicit optionality in v1 (C8 "bootstrap storm"
mitigation: new/legacy ADRs without `change_type:` emit a warning, not a
parse error).

Getting this table wrong — adding `adds`, omitting `adds-exception`,
treating `supersedes` as authorizing weakening — each re-opens a class of
forgery or ambiguity. Getting it right once lets the rest of the system
(`CrossField`, AppendOnly authorization lookups, the fix-block discipline)
be terse.

## Decision

### Enum (7 values)

`deprecates | weakens | narrows-scope | adds-exception | supersedes | clarifies | refines`

- `deprecates` — the requirement is going away.
- `weakens` — the requirement stays but its normative force is reduced.
- `narrows-scope` — the requirement's subject surface contracts.
- `adds-exception` — the requirement stays; a specific exclusion is added.
- `supersedes` — the requirement is being replaced by another id. `replaces:`
  must be non-empty and resolve in `current_state.index`.
- `clarifies` — non-behavioral wording change. Does not authorize any
  AppendOnly exception. Default for the W1.5 legacy-ADR backfill.
- `refines` — the spec literally lists this; kept in the enum even though
  no authorization work attaches to it in v1.

### Weakening set (4 values)

`{deprecates, weakens, narrows-scope, adds-exception}`

An ADR authorizes an AppendOnly exception (requirement deletion, MUST
downgrade, scenario regression, negative-polarity loss) only if its
`change_type` is in this set AND its `affects:` lists the id being
changed. `supersedes` is not in the weakening set — the replacement
requirement itself is still audited against R1.a/b/c/d through the
replacer id.

### Optionality

`change_type` is optional on ADRs in v1. When absent on an ADR that an
authorization lookup consults, AppendOnly emits
`append_only/missing_change_type` at `:warning`. The CrossField validator
emits a parallel warning on parse. This lets legacy specled_ex ADRs keep
working until W1.5's backfill lands, and lets adopters ship partial ADRs
during onboarding.

### Rejected / dropped

- `adds` (D3) — no authorization work attached; dropped from the enum.
- `modal_class_version` (B4) — the cache axis goes with Path B (see
  `specled.decision.modal_class_diff_time`); no version field on
  requirements.

## Consequences

- **Positive:** One small enum carries every AppendOnly authorization
  decision. `CrossField` rule 2 is a single `in_weakening_set?/1` check.
- **Positive:** Legacy ADRs parse cleanly under v1; the backfill stage
  (W1.5) is a mechanical edit.
- **Positive:** `refines` stays as a spec-literal label for documentation
  consistency; adopters don't have to fight the enum.
- **Negative:** Two enum values (`refines`, `clarifies`) are authorization
  no-ops in v1. Reviewers need to know that an ADR marked `refines` does
  not grant any weakening exception even though it looks meaningful.
  Documented in `decision_governance.spec.md` and W4's adopter guide.
- **Negative:** `change_type` being optional means a silent no-op ADR can
  exist. Mitigated by the `missing_change_type` warning; a project that
  wants strictness can promote the severity via
  `guardrails.severities`.
- **Negative:** Adding a new enum value later is a breaking change for
  downstream that destructures on the atom. v1 documents "additions
  require a new ADR" in the enum table.

## Related

- `specled.decision.adr_append_only` — the rule that makes this table
  load-bearing (you can't quietly rewrite `change_type` once accepted).
- `specled.decision.modal_class_diff_time` — the other half of the
  authorization axis.
- `specled.decision.finding_code_budget` — the containing enumeration
  that `append_only_finding_budget` extends.
