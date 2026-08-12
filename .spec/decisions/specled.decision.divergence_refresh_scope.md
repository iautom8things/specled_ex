---
id: specled.decision.divergence_refresh_scope
status: accepted
date: 2026-08-12
affects:
  - specled.api_boundary.divergence_blocks_refresh
change_type: narrows-scope
---

# Resolution-Path Divergence Excludes One Tier/MFA From Baseline Refresh

## Context

Resolution-path divergence originally blocked the orchestrator's entire
flat-tier refresh. One `api_boundary` MFA resolved through a different path
therefore froze unrelated `api_boundary`, `expanded_behavior`, `typespecs`,
and `use` baselines even though their hashes remained comparable. That scope
protected the diverged entry, but it coupled every other baseline to an
environment mismatch elsewhere in the run.

The attestation path already excludes divergent bindings by subject and MFA.
The hash store cannot use the same key: its shape is tier → MFA → entry and has
no subject dimension.

## Decision

A `branch_guard_resolution_path_divergence` finding excludes only its
`{tier, mfa}` entry from the flat-tier refresh. Other clean entries continue
to refresh when the existing drift and dangling gates permit the run to do so,
both normally and under `--accept-drift`.

The exclusion deliberately cannot be `{subject_id, mfa}`. Two subjects that
bind the same MFA share one stored baseline; if either binding diverges, that
`{tier, mfa}` entry is excluded for both subjects. Clean-binding attestations
remain subject-scoped and continue to exclude the finding's
`{subject_id, mfa}` pair.

## Consequences

- Unrelated flat-tier baselines no longer freeze because one api-boundary
  entry resolved through a different path.
- A shared MFA cannot be refreshed for one subject while remaining frozen for
  another; the store has only one entry to update or preserve.
- Drift and dangling findings remain run-wide refresh gates. In particular,
  when `--accept-drift` sees both same-path drift and divergence, refresh and
  drift silencing remain withheld together so the command never silences a
  baseline it did not heal.
- Severity `off` still suppresses only the displayed divergence finding. The
  raw finding continues to exclude the affected tier/MFA from refresh.

## Related

- `specled.decision.resolution_path_provenance` defines why cross-path hashes
  are incomparable and must not overwrite one another.
