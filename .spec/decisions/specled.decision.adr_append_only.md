---
id: specled.decision.adr_append_only
status: accepted
date: 2026-04-23
affects:
  - specled.append_only
  - specled.decisions
---

# ADR Files Are Append-Only; Structural Fields Are Immutable Once Accepted

## Context

The append-only discipline applied to requirements (R1.a-f) closes the
silent-weakening loophole on spec content, but leaves ADRs themselves
unguarded. An agent authoring a PR can:

1. Delete an accepted ADR that authorized a past exception, removing the
   paper trail for a weakening that already landed.
2. Edit `affects:` or `change_type:` on an accepted ADR to retroactively
   cover a new removal (C5: `affects:` mutability).
3. Flip `status: deprecated` back to `status: accepted` to resurrect a
   decision that was explicitly retired.

Each of these re-opens the class of failure AppendOnly was designed to
close. The governance story is incomplete if ADRs can be rewritten after the
fact.

The 2026-04-23 user directive, recorded in the refined plan's §1 and §3 W1
CrossField rule R5, strengthens the "C5 mitigation" reversible choice from
the prior refinement iteration into a hard rule that matches the
append-only semantics requirements already carry.

## Decision

1. **ADR files cannot be deleted from `.spec/decisions/` once committed.**
   Removal is detected by comparing the decision id lists between prior
   state and current state; a missing id emits
   `append_only/decision_deleted` at `:error`. The only authorized "removal"
   is a status transition to `deprecated` or `superseded` on the existing
   file.

2. **Structural fields on an accepted ADR are immutable.** Once an ADR has
   `status: accepted` in a landed `state.json`, its `affects`, `change_type`,
   and `reverses_what` fields must be byte-identical in all subsequent
   states. Violations emit `append_only/adr_affects_widened` at `:error`
   plus a CrossField error from rule R5.

3. **Status transitions are forward-only.** `accepted` may transition to
   `deprecated` or `superseded`. `deprecated` and `superseded` are
   terminal — no transition back to `accepted`. This is the single
   mutation allowed, and it is the mechanism that makes append-only work.

4. **To change a decision, author a new ADR.** The new ADR uses
   `change_type: deprecates` or `change_type: supersedes` with the old
   id in `replaces:` (for supersedes). The old ADR file stays in the
   repo with its `status:` updated.

## Consequences

- **Positive:** The governance invariant is one-way. No agent can silently
  undo a past authorization, and the history of decisions is reconstructible
  from the current `.spec/decisions/` tree without consulting Git.
- **Positive:** Review is mechanical. A reviewer checks the diff for any
  ADR file deletion and for any non-status field change on an accepted
  ADR; both cases are caught by the detectors.
- **Negative:** More ADR files over time. A long-lived project accumulates
  historical ADRs that are all in the `deprecated` / `superseded` state.
  Expected; the file tree is the history.
- **Negative:** Bootstrap cost. Existing ADRs without `change_type:` need
  a one-time backfill (W1.5 adds `change_type: clarifies` to the 19 legacy
  ADRs in `specled_ex/.spec/decisions/`). After backfill, the rule turns
  on cleanly.
- **Pairs with:** `specled.decision.change_type_enum_v1` (defines the
  enum values used by `change_type:`) and CrossField rule R5 (the
  structural validator run at parse time).
