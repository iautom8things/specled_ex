---
id: specled.decision.coverage_identity_joins
status: accepted
date: 2026-07-25
affects:
  - specled.coverage_capture
  - specled.triangulation
  - specled.spec_review
change_type: clarifies
---

# Coverage Identity Joins Fail Toward Explicit Unknowns

## Context

Per-test capture and review joined coverage through identities that were
independently derived and insufficiently classified. Compile-source paths could
be absolute while persisted record paths were relative. A formatter file-map
miss deleted a module's lines from both the per-test payload and the aggregate
remainder. Review also grouped missing module indexes, missing MFA line entries,
unresolved sources, and malformed MFA strings into either `no_debug_info_mfas`
or ordinary uncovered coverage. Finally, a subject reach map without an
`:attribution` key rendered as if it explicitly claimed exact attribution.

Each fallback strengthened the apparent claim precisely when the join evidence
was weakest.

## Decision

Coverage source identity is the normalized repository-root-relative path.
Capture normalizes compile sources before persistence, and triangulation
normalizes both sides of its record-to-module join to that identity.

The formatter derives one module-to-source map from the suite-start module scope
and reuses it for boundary payload and remainder compaction. Hit modules that
cannot be mapped are retained in `meta.unmapped_modules`; their lines are never
fabricated under a different file.

Per-test MFA reach keeps four disjoint result partitions:

- `covered_mfas` and `uncovered_mfas` only when source and line identities
  resolve;
- `no_debug_info_mfas` only for the line index's explicit
  `:no_debug_info` state;
- `unresolvable_source_mfas` for absent module indexes, absent MFA line
  entries, unresolved compile sources, and malformed MFA identities.

Unresolvable MFAs remain in `closure_mfa_count` and contribute zero executed
MFAs. This deliberately lowers or preserves the reported percentage rather
than removing unknown evidence from the denominator.

Review qualifiers require explicit provenance. Only `:attribution => :exact`
or `:attribution => :degraded_unhooked` publishes a qualifier; a missing key is
unqualified.

## Consequences

- Capture artifacts use one stable path identity and disclose mapping loss.
- Review distinguishes lack of abstract code from all other identity failures.
- Coverage percentages never improve merely because a source join failed.
- Older or hand-built subject reach maps without attribution no longer inherit
  the exact-within-chained-windows claim.
- The exact claim for explicitly attributed hooked windows remains unchanged:
  exact only within the disclosed chained windows described by
  `specled.decision.per_test_sync_boundary`.

## Related

- `specled.decision.per_test_sync_boundary` — defines the bounds of an explicit
  exact attribution claim.
- `specled.decision.coverage_qualifier_requirement_ids` — names the current
  qualifier contracts.
