---
id: specled.decision.decision_fork_advertised_at_decision_points
status: accepted
date: 2026-07-22
affects:
  - specled.next
  - specled.branch_guard
  - specled.prime
  - specled.spec_drift_trailer
change_type: clarifies
---

# The Missing-ADR Condition Is Advised as a Fork, Not an ADR Mandate

## Context

Both places that surface the missing-ADR condition were one-armed: the
`needs_decision_update` guidance in `mix spec.next` said only "add or revise
an ADR", and the `branch_guard_missing_decision_update` finding carried no
`fix:` block at all. The sanctioned alternative — a
`Spec-Drift: branch_guard_missing_decision_update=info` git trailer — was
documented only in the skill's escape-hatches section, far from the moment of
decision.

Downstream evidence (Atlas repo, specled_-4kg): ~210 decision files in ~8
weeks, roughly a third commit-grade (module renames, form-state fixes,
temporary shims) — exactly what `decisions/README.md` says does not belong.
Agents follow the router's literal text; the one-armed sentence produced
filler ADRs. Atlas's workaround — demoting the finding code to `:warning`
repo-wide in config — lost the gate entirely while agents still complied
with the warning.

## Decision

Every surface that describes the missing-ADR condition states the rubric
first and then both resolution arms, with the ADR as the affirmative arm:

1. Rubric: does the branch change durable cross-cutting policy — does it
   constrain future changes, span subjects beyond this branch, or record a
   rejected alternative?
2. If yes: add or revise an ADR (`mix spec.decision.new <id> --title "..."`).
3. If no: record `Spec-Drift: branch_guard_missing_decision_update=info` as
   a git trailer on a commit in the range, with a one-line reason in the
   commit body.

Surfaces covered: `mix spec.next` `needs_decision_update` steps, the
`branch_guard_missing_decision_update` finding's `fix:` block (same
code-fenced convention as `append_only/*`), the `mix spec.prime` loop line,
and the generated scaffold docs (`README.md`, local skill).

Per-code config demotion as the answer to filler-ADR pressure is rejected:
it is policy-wide and silent, whereas trailers are per-range, carry a
reason, and stay auditable in commit history and review.

## Consequences

- Positive: an agent that judges a change non-durable has a named, auditable
  way to clear the verdict instead of writing a filler ADR.
- Positive: each "no ADR needed" call is individually visible in history,
  unlike a config demotion.
- Negative: advertising a silencing mechanism in the main loop risks
  reflexive use. Mitigated by ordering (rubric first, ADR affirmative) and
  by requiring the trailer to carry a reason.
- Trailer semantics are unchanged: range-wide, `trailer > config > default`,
  config `:off` absorbing.
