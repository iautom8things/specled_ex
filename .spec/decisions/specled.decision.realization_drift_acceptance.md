---
id: specled.decision.realization_drift_acceptance
status: accepted
date: 2026-07-23
affects:
  - specled.realized_by
  - specled.branch_guard
  - specled.spec_drift_trailer
change_type: introduces
---

# Intentional realization drift is accepted by refreshing the committed baseline

## Context

When a function's realization intentionally changes — a new clause, a reshaped
head, a rewritten body under an `implementation` binding — `mix spec.check`
emits `branch_guard_realization_drift` because the current canonical hash no
longer matches the committed one in `.spec/realization_hashes.json`. Before this
decision there was no first-class way to say "yes, this drift is intended;
adopt the new hash." Three defects made intentional drift a trap
(discovered fixing `main@a4bfd3b`):

1. **The refresh that would accept the drift was gated on the drift being
   absent.** `Orchestrator.refresh_and_commit_hashes/3` ran only when
   `has_drift?(findings)` was false — severity-independent. So the presence of
   drift blocked the very refresh that would commit the new hash. `mix
   spec.check` could never self-heal intentional drift on its own.

2. **The `Spec-Drift:` trailer is ephemeral.** A `Spec-Drift:
   branch_guard_realization_drift=info` trailer downgrades the finding only
   while the carrying commit sits inside `base..HEAD`
   (`specled.decision.spec_drift_base_to_head`). Once the branch merges and the
   commit falls at or behind the base, `Trailer.read` sees an empty range, the
   override vanishes, and — because the committed hash was never updated (defect
   1) — the drift returns as an error on `main` forever.

3. **The only working ritual was undocumented.** Deleting the stale entry from
   `.spec/realization_hashes.json` and letting the silent-seed pass reseed it
   (sanctioned by `specled.realized_by.silent_seed`) worked, but was written
   down nowhere as the acceptance flow.

## Decision

Add an explicit, durable acceptance path: `mix spec.check --accept-drift`.

- The task threads `accept_drift?: true` into
  `SpecLedEx.Realization.Orchestrator`. When set, the orchestrator runs
  `refresh_and_commit_hashes/3` **even though drift findings are present**,
  committing the current flat-tier hashes as the new baseline via
  `HashStore.merge/2`. The next `mix spec.check` sees committed == current and
  emits no drift — the fix survives the merge, unlike the trailer (defect 2).

- **Dangling bindings are never accepted.** `refresh_and_commit_hashes/3` and
  the shared `api_boundary_hashes/2` hasher only commit hashes for bindings that
  resolve, so a `branch_guard_dangling_binding` finding keeps failing the run.
  You cannot accept a binding that does not exist.

- For the accepting run, `SpecLedEx.BranchCheck` injects a run-scoped
  `branch_guard_realization_drift => :info` override at **trailer precedence**
  (the highest tier in `Severity.resolve/3`), so the run passes in one shot and
  records what was accepted. The explicit flag deliberately wins over a
  `branch_guard.severities` config pin of `:error` — typing `--accept-drift` is
  a stronger, one-time acknowledgment than that standing config, exactly as a
  `Spec-Drift:` trailer overrides config. A config `:off` still absorbs the
  finding (off is absorbing), and only the drift code is touched.

- `--accept-drift` is a **whole-run** accept: it refreshes every currently
  drifted flat-tier binding. Review the drift report before running it — it is
  the moral equivalent of `git add -A` after reading the diff. Per-MFA scoping
  is deferred to a follow-up.

After running `mix spec.check --accept-drift`, commit the updated
`.spec/realization_hashes.json` alongside the code change that caused the drift.

## Scope: which drift each mechanism accepts

- **Flat tiers** (`api_boundary`, `expanded_behavior`, `typespecs`, `use`, and
  bare-module `api_boundary` head-union entries reached via the implication):
  accepted durably by `--accept-drift`.
- **Implementation-tier closure and bare-module full-union hashes**: still
  seed-only (they are excluded from `refresh_and_commit_hashes/3`; see
  `specled.branch_guard.tier_dispatch_commits_hashes_on_clean`). Accept these by
  the delete-and-reseed ritual: remove the stale entry from
  `.spec/realization_hashes.json` under `implementation` and let the next `mix
  spec.check` silent-seed pass recompute it
  (`specled.realized_by.silent_seed`).

## Consequences

**Positive.** Intentional drift is now self-healing and merge-durable. The
trailer reverts to its intended role — a PR-scoped acknowledgment that a finding
is expected for the lifespan of a branch — not a load-bearing acceptance
mechanism that silently stops working post-merge.

**Positive.** Acceptance is explicit and auditable. Nothing is absorbed unless a
maintainer types `--accept-drift`; a stray trailer does not silently rewrite the
baseline.

**Negative — whole-run granularity.** `--accept-drift` accepts every currently
drifted flat-tier binding, not a named subset. A maintainer who means to accept
one drift while another is unintended must stage them separately or review the
report first. Per-MFA scoping is a tracked follow-up.

**Negative — two acceptance surfaces.** Flat-tier drift accepts via the flag;
implementation-tier drift accepts via delete-and-reseed. This is documented in
`docs/concepts.md` and above; unifying them waits on an implementation-tier
refresh helper (the same follow-up that
`specled.branch_guard.tier_dispatch_commits_hashes_on_clean` already anticipates).

## Alternatives considered

- **Tie acceptance to the trailer** (refresh when the run's trailer downgrades
  drift to `:info`). Rejected: implicit — any run carrying the trailer would
  silently rewrite the baseline, absorbing co-occurring unintended drift — and
  it inherits the trailer's `base..HEAD` fragility, so it would not fire on the
  post-merge run where the baseline most needs updating.
- **Make the refresh gate severity-aware instead of adding a flag.** Same
  implicitness problem: it couples baseline mutation to severity config a
  reviewer may not have intended as an accept signal.
- **Drop the no-drift gate entirely** (always refresh). Rejected: that absorbs
  every drift on every run, defeating drift detection.
