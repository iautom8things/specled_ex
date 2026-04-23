---
id: specled.decision.modal_class_diff_time
status: accepted
date: 2026-04-23
affects:
  - specled.modal_class
  - specled.append_only
change_type: clarifies
---

# Modal Class Is Computed at Diff Time, Never Cached

## Context

`AppendOnly.detect_must_downgrade/3` needs to know whether the modal
strength of a requirement statement was reduced between base and head
(`MUST` → `SHOULD`, `SHALL NOT` → `MAY`, etc.). Two places could hold the
classification:

- **Path A (caching):** `mix spec.validate` runs the classifier, writes
  the resulting atom into each requirement entry in `state.json`, and
  AppendOnly reads it from both prior and current state.
- **Path B (diff-time):** AppendOnly invokes the pure classifier on both
  `prior.statement` and `current.statement` when it needs the comparison;
  `state.json` never carries a `modal_class:` field.

Red-team 04a C4 flagged that Path A is structurally vulnerable to
"classifier version skew" — if detector rules change between versions,
statements hashed under v1 and re-classified under v2 would differ, and
the cached value on the prior-state entry would be stale. The mitigation
options were a `modal_class_version:` field per entry, an invalidation
axis, or dropping the cache entirely.

D1 picked dropping the cache. v1 ships exactly one classifier; there is no
version to drift from. The BLOAT finding B4 (`modal_class_version`) is
paired with this decision: no cache means no version, no cache-invalidation
axis, no second code path.

## Decision

- `SpecLedEx.ModalClass.classify/1` is pure and runs only when
  `AppendOnly.detect_must_downgrade/3` (or a test) asks.
- Neither the requirement struct nor `state.json` carries a `modal_class:`
  field. The classifier is the only source of truth at diff time.
- There is one classifier version in v1. `modal_class_version` is
  explicitly cut from the schema (B4).
- `downgrade?/2` is total over modal × modal and monotonic on the
  partial order; its contract is tested independently.

## Consequences

- **Positive:** No version-skew class of bug is reachable in v1. Every
  invocation classifies afresh from `statement`.
- **Positive:** Zero storage cost; `state.json` stays minimal.
- **Positive:** Schema stays stable across classifier upgrades; only the
  classifier module changes.
- **Negative:** AppendOnly pays a classifier call per requirement per diff.
  Measured cost on specled_ex's own `state.json` is sub-millisecond total;
  revisit only if a target repo shows runtime concern.
- **Negative:** A future detector upgrade would retroactively reinterpret
  historical statements. v1 has no actual exposure; v1.1 revisiting
  classifier heuristics would need to introduce a Path C (versioned
  classifier with explicit migration semantics) rather than silently
  flipping behavior.
- **Pairs with:** `specled.decision.change_type_enum_v1` (the
  authorization axis) and `specled.append_only.must_downgraded` (the
  detector that consumes the classifier).
