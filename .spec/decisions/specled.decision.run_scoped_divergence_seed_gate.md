---
id: specled.decision.run_scoped_divergence_seed_gate
status: accepted
date: 2026-08-12
affects:
  - specled.realized_by
  - specled.branch_guard
change_type: narrows-scope
---

# Resolution-Path Divergence Makes Silent Seeding Run-Scoped

## Context

Realization hashes record whether an api-boundary binding resolved from BEAM or
source. Comparing across those paths is invalid, so a labeled cross-path
encounter emits `branch_guard_resolution_path_divergence` and protects the
committed entry from refresh.

Silent seeding had a separate hole. It ran before detection and wrote every
missing entry immediately. On a cold or stale build, an uncommitted public MFA
could fall back to source and receive `resolved_via: "source"`, even though a
warm production run would resolve it from BEAM. No per-MFA divergence gate can
catch that case: detectors deliberately return no finding when the MFA has no
committed baseline, so there is no path to compare.

Moving seeding after detection is finding-neutral by itself for the same reason.
It changes neither the missing entry's empty finding result nor the evidence
available for a per-MFA decision.

The resulting source label is harmful but recoverable. Later warm runs emit
divergence and preserve the entry until a maintainer deletes it, as the
`branch_guard_resolution_path_divergence` remediation already instructs. The
defect is therefore a stale label that survives until entry deletion, not a
permanently stuck baseline.

## Decision

1. Tier dispatch runs before silent seeding so the orchestrator has the complete
   normalized finding set for the run.
2. The existing divergence-derived `{tier, mfa}` set serves two purposes without
   changing its grain. It continues to exclude only those pairs from flat-tier
   refresh. Its emptiness is also the coarse run-scoped seed gate: when the set
   is non-empty, the tree is considered cold and no missing entry in any tier is
   seeded.
3. Detectors remain finding-neutral for missing baselines. A run with no
   divergence silently seeds missing resolvable entries after dispatch and still
   emits no drift for them.
4. On a divergent run, flat-tier refresh may still update committed,
   non-divergent entries under
   `specled.decision.divergence_refresh_scope`. It must exclude every missing
   flat-tier entry so refresh cannot bypass the seed gate by creating it. The
   implementation tier has no refresh path and is protected by skipping its
   silent seed.
5. The existing `commit_hashes?` and umbrella gates remain unchanged. This
   decision does not alter legacy unlabeled comparison, resolution
   discrimination, per-MFA refresh scoping, or the hasher version.

## Consequences

- One divergence anywhere prevents a cold or stale tree from assigning path
  provenance to any newly tracked entry during that run.
- A single divergence can delay legitimate first-run seeds elsewhere until a
  later warm run. This is intentional: the run has already demonstrated that
  its resolution environment is not trustworthy for new provenance.
- Existing committed clean entries continue to refresh, preserving the narrow
  refresh behavior established by
  `specled.decision.divergence_refresh_scope`.
- A source label written before this gate remains recoverable through the
  existing delete-and-reseed remedy.

## Alternatives Considered

- **Gate only the divergent MFA.** Rejected because a missing MFA cannot emit
  divergence; this reproduces the defect unchanged.
- **Only move seeding after dispatch.** Rejected because missing baselines are
  finding-neutral, so ordering alone supplies no new evidence.
- **Treat `[:beam_fn_missing]` as proof of a stale build.** Rejected because
  legitimate private functions have the same resolution signature; this would
  suppress valid seeds.
