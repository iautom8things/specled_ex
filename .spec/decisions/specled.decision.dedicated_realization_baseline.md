---
id: specled.decision.dedicated_realization_baseline
status: accepted
date: 2026-07-02
affects:
  - specled.binding
  - specled.index_state
  - specled.realized_by
  - specled.api_boundary
  - specled.append_only
  - specled.policy_files
change_type: refines
---

# Committed Realization Baseline Lives In `.spec/realization_hashes.json`, Not `state.json`

## Context

`.spec/state.json` was a hybrid file: a large derived index (requirements,
scenarios, verification results — fully recomputable from spec files) fused
with the committed realization-hash baseline that drift detection compares
against. The fusion had two costs:

1. **Consumer churn and conflicts.** In a large consumer repo (Atlas, 157
   subjects) state.json was the most-churned file (203 commits in 2026, 3×
   the runner-up) and conflicted on essentially every rebase where two
   branches touched specs. The documented conflict ritual — take either
   side, regenerate, commit — recomputed the hash baseline from the merged
   tree, silently absorbing exactly the realization drift the tiers exist
   to flag.

2. **A latent in-run bug.** `SpecLedEx.write_state/4` regenerates state.json
   without a `realization` key, and `mix spec.check` calls it *before* the
   branch guard runs the realization orchestrator. The committed baseline
   was therefore wiped from the working tree before `HashStore.read/2` ever
   consulted it: every check run silently re-seeded from the current tree,
   and drift detection could not fire inside the `mix spec.check` pipeline.

## Decision

The committed realization baseline lives in a dedicated committed file,
`.spec/realization_hashes.json`, whose top level is the tier → binding-key →
entry map, serialized canonically (recursively sorted keys) so diffs read as
subject-level realization changes. `HashStore.write/2` and `merge/2` keep
their atomic `.tmp` + fsync + rename semantics against that file.

`.spec/state.json` becomes freely regenerable derived state. Consumers may
gitignore it or regenerate it in CI without defeating drift detection, and
the take-either-side conflict ritual is safe for it.

Migration is one-shot and automatic: `HashStore.read/2` falls back to the
`realization` key of an existing state.json while the dedicated file is
absent, `HashStore.merge/2` reads through the same fallback so legacy
entries are carried forward, and `SpecLedEx.write_state/4` hoists a legacy
embedded section into the dedicated file before regenerating state.json
(which would otherwise destroy it). Once the dedicated file exists it is
authoritative and any embedded section is ignored.

Both `.spec/state.json` and `.spec/realization_hashes.json` are dropped from
branch-guard change sets as tool-managed files: the former is derived, the
latter is rewritten by the tooling's own seed/refresh passes.

## Consequences

- **Positive:** Baseline survives state.json regeneration; drift detection
  works inside `mix spec.check`; merge conflicts in state.json become noise
  resolvable by regeneration; baseline diffs are small and reviewable.
- **Negative:** One more committed file under `.spec/`; conflicts in the
  baseline file itself must be resolved deliberately (never by
  regeneration), which the workspace guidance now spells out.
- Historical references to hashes "committed in state.json" in specs and
  ADRs predating this decision should be read as the dedicated baseline
  file.
