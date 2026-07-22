---
id: specled.decision.sync_noop_short_circuit_and_auto_prune
status: accepted
date: 2026-07-22
affects:
  - specled.evidence_store.prune_explicit_only
  - specled.evidence_store.sync_auto_prune
  - specled.evidence_store.sync_noop_short_circuit
  - specled.tasks.prune_evidence
change_type: adds-exception
reverses_what: >-
  The "sync shall never prune" clause of specled.evidence_store.prune_explicit_only:
  entries were previously deletable only by an explicit `mix spec.prune`
  invocation. Sync may now also drop entries, but only through the same
  reachable-tree-hash keep-set prune already computes, and only once a size
  threshold is crossed during a real (non-no-op) reconciliation — never
  unconditionally, and never on the no-op path.
---

# Sync: O(1) No-Op Short Circuit, and Auto-Prune Folded In On a Size Threshold

## Context

`/critical-review` of specled_-csg (finding F2) flagged two related costs in
`SpecLedEx.Evidence.Sync.run_attempt/4`:

- **Hot-path waste.** Every sync attempt loaded and decoded every entry on
  both the local and remote refs before checking whether they even differed
  — `git cat-file` per entry, both sides, roughly 2-4N subprocesses — even
  when the outcome was always going to be `:noop`. This is the case the
  pre-push hook hits on nearly every push, so the cost scales with total
  store size on the path that runs the most and should cost the least.
- **Unbounded ratchet.** One entry per verified tree state accumulates
  without limit — projected ~2k entries within months for an active team,
  ~30-60s on the pre-push path. `mix spec.prune` already computes the
  correct reachability-based keep-set, but nobody runs it automatically, so
  the store only shrinks when a human remembers to invoke it.

`specled.decision.evidence_orphan_branch_split` considered "prune-on-sync"
as an alternative store design and rejected it: "turns every push
destructive and creates non-monotonic reads mid-review." That rejection
targeted unconditional pruning on every sync, which would drop
still-relevant entries the moment a supporting branch went out of scope
mid-review. This decision does not reopen that: the exception below is
scoped to a size threshold that fires rarely relative to the many
no-drift/small-delta syncs the pre-push hook performs, and reuses prune's
own reachable-from-live-refs computation — an entry reachable from any
retained branch head or remote-tracking ref is never a pruning candidate,
same as an explicit `mix spec.prune` invocation.

## Decision

1. **No-op short circuit.** In `run_attempt/4`, once the fetched remote
   commit and the local `spec-evidence` commit are compared and found
   equal, and no explicit `:keep` was supplied, `run/2` returns
   `%{ahead: 0, behind: 0, action: :noop, warnings: []}` immediately —
   before any `ls-tree` or `cat-file` call. Nothing changed since the last
   sync, so nothing needs reading. `specled.evidence_store.sync_noop_short_circuit`
   states this.

2. **Auto-prune on a size threshold.** When there is real reconciliation
   work (local and remote refs differ) and no explicit `:keep` was
   supplied, `reconcile_entries/6` now compares the merged entry count
   against `@auto_prune_entry_threshold` (`:auto_prune_threshold` in opts
   overrides it, mainly for tests). Once crossed, it computes the
   reachable-tree-hash keep-set via the same `Sync.reachable_keep_set/1`
   function `mix spec.prune` calls, and filters the merged tree before
   writing and pushing — one prune-shaped operation folded into the sync
   that was going to run anyway. Below the threshold, or if the keep-set
   computation errors, sync proceeds as a plain unpruned merge; auto-prune
   is housekeeping, not a correctness gate, and never fails an attempt that
   would otherwise have succeeded. `specled.evidence_store.sync_auto_prune`
   states this; `specled.evidence_store.prune_explicit_only` is narrowed
   from "sync shall never prune" to "deletion only ever happens through
   this one shared reachable-set computation, whether invoked explicitly or
   by sync's own threshold trigger."

3. **`mix spec.prune` keeps working, now via the shared function.**
   `Mix.Tasks.Spec.Prune` no longer duplicates the reachable-set query; it
   calls `SpecLedEx.Evidence.Sync.reachable_keep_set/1` (the function
   auto-prune uses internally) and passes the result as `keep:` to
   `Sync.run/2`, same as before. Its own behavior — and the
   `prune_drops_only_unreachable` scenario that pins it — is unchanged.

Both properties are exercised in `test/specled_ex/evidence/sync_test.exs`:
a no-op sync against a tree holding a quarantined entry surfaces zero
warnings (proving no entry was re-read), and a real reconciliation with the
threshold set below/above the merged entry count prunes/keeps an
unreachable entry accordingly.

## Consequences

- **Positive:** the pre-push hook's common case (nothing changed) no longer
  scales with store size. The store gains a self-limiting mechanism that
  doesn't depend on a human running `mix spec.prune`.
- **Positive:** the exception is narrow and auditable — same keep-set
  computation, same reachability semantics, same lease-guarded push, gated
  by a threshold instead of "every time."
- **Negative:** a large real reconciliation that happens to cross the
  threshold pays the reachable-set query cost (a `for-each-ref` plus one
  `git log --format=%T`) on top of the merge it was already doing. This is
  strictly cheaper than the entry-loading cost it replaces the manual
  `mix spec.prune` invocation for, and only fires when there was already
  work to do.
- **Negative:** the threshold is a single repo-wide constant
  (`@auto_prune_entry_threshold`, overridable via `:auto_prune_threshold`
  for tests and advanced callers), not per-project tunable from the CLI.
  Acceptable for v1; a `mix spec.sync` flag can be added later if a project
  needs a different value without code changes.
- **Pairs with:** `specled.decision.evidence_orphan_branch_split` (the
  store design this refines) and `specled.decision.change_type_enum_v1`
  (defines `adds-exception`, used here since the general
  explicit-only rule stands and a specific, bounded exception is carved
  out of it).
