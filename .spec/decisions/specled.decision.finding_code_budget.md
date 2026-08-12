---
id: specled.decision.finding_code_budget
status: accepted
date: 2026-04-21
affects:
  - specled.api_boundary
  - specled.triangulation
  - specled.use_tier
  - specled.prose_guard
  - specled.implementation_tier
  - specled.branch_guard
change_type: clarifies
---

# v1 Ships Exactly Seven New Branch-Guard Finding Codes; Additions Require Spec Justification

## Context

Red-team 04c (scope audit) tallied 12 new finding codes in the original
architecture. The auditor judged 5 of those as bloat (auto-emitted info
findings for things that belong in summary lines, speculative codes for
rare cases, per-subject opt-out findings that duplicate config.severities).
Collapsing cuts #9, #11, #12 plus deferrals #10, #13 brought the count to 7
— which matches the count named in the original spec (pre-architecture
inflation).

Uncontrolled finding-code inflation is its own failure mode: users stop
reading findings whose names they do not recognize. Every new code is a new
surface to document, configure, and reason about.

## Decision

v1 ships the following nine finding codes total. Seven are new with this
feature; two of the "S1 non-binding" codes reuse existing branch_guard
infrastructure but are newly specified in this slice:

**Realization-tier codes (new):**
- `branch_guard_dangling_binding`
- `branch_guard_realization_drift`
- `branch_guard_untested_realization`
- `branch_guard_untethered_test`
- `branch_guard_underspecified_realization`
- `suggest_realized_by_migration`
- `detector_unavailable`

**S1 prose/guard codes (new with this slice):**
- `branch_guard_test_only_change` (info severity) <!-- spec-lint:allow-code=branch_guard_test_only_change budgeted in S1 planning; never emitted — the test-only-change flow is expressed by the absence of realization findings, not a dedicated code -->
- `spec_requirement_too_short` (info severity)

Any finding code added during implementation must justify against this list
via a spec amendment + PR note. "While I was in here I needed to emit X"
is not sufficient; the reviewer declines such PRs.

## Consequences

- Positive: the documentation surface stays shallow enough that users can
  read and remember every code.
- Positive: severity-resolver config lookup remains tractable; each code
  gets one per-code default entry.
- Negative: genuinely useful new findings discovered during implementation
  must wait for a spec update. In practice the spec review cycle is short;
  this has not been observed to block real work in the project's history.
- Negative: enforcement is social (code review), not mechanical. A test
  could be added that greps `lib/specled_ex/**` for finding-code atoms and
  fails CI if the set drifts, but is not required in v1.

## Amendment 2026-08-11 — tenth code: `branch_guard_resolution_path_divergence` (specled_-n5q.1)

**Counting rule.** "Tenth" counts entries on THIS ADR's Decision list (nine),
not codes emitted by the implementation. The two are not the same set, and
saying so here stops the number drifting into a false claim:

- `suggest_realized_by_migration` and `branch_guard_test_only_change` are <!-- spec-lint:allow-code=branch_guard_test_only_change budgeted in S1 planning; never emitted — restated here by the counting rule, same status as the Decision-list entry above -->
  budgeted but never emitted — they hold slots against future use. The
  latter carries an allow-marker recording why, on both mentions.
- `branch_guard_realization_unknown_tier` is emitted by
  `SpecLedEx.BranchCheck` but was never added to this list. It predates this
  amendment and is grandfathered, not authorized by it; it should be
  reconciled onto the list (or removed) by the ticket that next touches
  unknown-tier handling.

So: ten budgeted codes after this amendment, of which eight are emitted, plus
one emitted-but-unbudgeted code awaiting reconciliation. Any future
"Nth code" claim in this ADR counts budget slots by the same rule.

Justified against this list rather than around it. The code does not add a
new emission surface: it RE-CLASSIFIES a subset of what
`branch_guard_realization_drift` previously emitted — the cross-path
comparison case, where the baseline hash and the current head were produced
by different resolution paths (BEAM debug_info vs source-AST fallback) and
the hash disagreement is therefore structural, not evidence about the code.
Before this code existed, users encountering that case read a WRONG code:
plausible-looking drift for functions nobody changed, which misled a real
adopter review. Naming it separately is the anti-bloat position —
one honest code instead of one dishonest emission of an existing code.

Bounded scope: emitted only by the api_boundary tier, only for labeled
baseline entries whose `resolved_via` differs from the current resolution
path. Default severity `warning`; one per-code default entry
(`SpecLedEx.BranchCheck` `@per_code_defaults`); documented in
`docs/adoption.md` and `docs/concepts.md`. See
`specled.decision.resolution_path_provenance` for the full design.
