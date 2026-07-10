---
id: specled.decision.silent_seed_batches_subject_graph
status: accepted
date: 2026-07-10
affects:
  - specled.realized_by
  - specled.implementation_tier
  - specled.branch_guard
change_type: clarifies
---

# Silent-Seed Batches the Full Subject Graph; Flat-Tier Refresh Merges

## Context

The implementation tier composes a subject's hash from its own closure plus a
hash-reference to every peer subject the closure reaches
(`specled.implementation_tier.hash_ref_composition`): the hash input embeds
`"subject:#{B.id}:hash:#{B.impl_hash}"` for each peer `B`. Resolving `B`'s hash
requires `B` to be present in the world the hasher walks.

Two defects in the silent-seed / hash-commit path (atlas-vmi) made a freshly
seeded baseline non-reproducible, so `mix spec.check` reported wholesale
`branch_guard_realization_drift` on every run after a seed:

1. **Per-subject seeding.** The orchestrator seeded each subject in isolation,
   calling `Implementation.hashes_for_seeding/3` with a single-element list.
   That builds a world containing only subject `A`, so a peer reference to `B`
   cannot resolve and the seed writes `subject:B:hash:unknown`. The detector
   walks the full subject graph, embeds `B`'s real hash, and the committed
   entry never matches — permanent drift.

2. **Clean-run refresh replaced the baseline.** `refresh_and_commit_hashes/3`
   recomputes only the four flat tiers, but wrote them with
   `HashStore.write/2`, replacing the entire baseline and wiping the
   silent-seeded `implementation` section on every clean run.

## Decision

1. **The silent-seed pass computes closure hashes over the full MFA-subject
   graph in one `hashes_for_seeding/3` call**, then persists only the
   uncommitted ids. Bare-module bindings are partitioned out per subject at
   hash time (matching `Implementation.run/4`'s world), so the in-project set
   and peer graph the seeder sees are identical to the detector's. Seeding a
   subject against a partial world is prohibited.

2. **`refresh_and_commit_hashes/3` uses `HashStore.merge/2`, not `write/2`.**
   Merging the recomputed flat tiers over the existing baseline preserves the
   silent-seeded `implementation` section. `write/2` retains full-baseline
   replacement semantics for callers that intentionally rewrite the file.

The implementation tier remains seed-only (no flat-tier-style refresh) until a
dedicated refresh helper that can rebuild its `world` map lands.

## Consequences

- A batch-seeded baseline is reproducible by the detector: no false drift.
- The realization baseline is regenerable rather than a hand-maintained
  artifact, consistent with the append-only + regenerate-baseline discipline.
- Guarded by `OrchestratorTest` ("batches the full subject graph when seeding
  hash-ref peers") and `ImplementationTest` ("silent-seed batching"), the
  former verified to fail on the pre-fix commit.
