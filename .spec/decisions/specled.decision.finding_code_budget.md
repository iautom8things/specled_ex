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
- `branch_guard_test_only_change` (info severity)
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
