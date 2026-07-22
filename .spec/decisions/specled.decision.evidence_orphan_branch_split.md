---
id: specled.decision.evidence_orphan_branch_split
status: accepted
date: 2026-07-16
affects:
  - specled.index_state
  - specled.append_only
  - specled.branch_guard
  - specled.spec_review
  - specled.mix_tasks
  - specled.evidence_store
  - specled.index.canonical_state_output
change_type: deprecates
reverses_what: >-
  The committed-.spec/state.json contract: spec.check/spec.index/spec.validate
  writing state.json to the working tree by default
  (specled.index.canonical_state_output as a default-on write), AppendOnly
  baselines read via `git show <base>:.spec/state.json`
  (specled.append_only / specled.branch_guard committed-baseline pins), and
  FindingsDelta's base findings read from the committed state.json at the
  base ref (specled.spec_review.findings_delta,
  specled.spec_review.findings_delta_base_fallback).
---

# Evidence Ledger Split: Orphan-Branch Store Replaces Committed state.json

## Context

`.spec/state.json` (578KB, committed) fused ~75% regenerable parse cache with
~25% irreplaceable execution evidence. Every spec-touching PR paid churn,
rebase conflicts, and regenerate-post-rebase ceremony on content that is
mostly cache, and base-ref comparisons (weakening detection, findings delta)
inherited parser-version skew from stale committed snapshots. The documented
conflict ritual — take either side, regenerate, commit — was pure ceremony
that landed on agents in concurrent-worktree workflows, the workload specled
is built for. `specled.decision.dedicated_realization_baseline` already moved
the realization baseline out for exactly these reasons; this decision
finishes the job for the rest of the file.

## Decision

Split cache from evidence and change where each lives:

- **Cache is never committed again.** Current-tree views are parsed live;
  base-ref views are parsed from the base tree's `.spec/` sources (specs AND
  decisions, enumerated via `git ls-tree`) with the *current* parser —
  eliminating parser-version skew in spec-parse comparisons. Summary is a
  derived view. `mix spec.check` stops writing state.json; `spec.index` /
  `spec.validate` write only under explicit `--output`.
- **Evidence moves to an orphan `spec-evidence` branch**, one file per entry
  keyed by tree hash (`git rev-parse <ref>^{tree}`; current tree mirrors
  `git add -A`), written locally by `mix spec.check` (CAS, zero network) and
  reconciled by explicit `mix spec.sync` (plumbing-only tree-union merge,
  lease-guarded push), automated by a specled-shipped pre-push hook. Same-key
  conflicts resolve by highest run stamp, identically local and remote.
- **No legacy fallback reader** for base state.json at old refs; migration
  (`mix spec.evidence.migrate`) seeds current evidence and older history
  degrades softly. `.spec/realization_hashes.json` stays in-tree, unchanged.
- **Trust boundary:** evidence is an unauthenticated attestation — input to
  presentation and advisory review only, never to merge gates or CI pass/fail.

Considered alternatives, rejected: git-notes as the store (poor multi-writer
merge semantics vs per-entry tree files); a per-tree-hash ref namespace
(`refs/spec-evidence/<hash>` — ref bloat, no atomic multi-entry sync); an
in-tree evidence file (re-creates the churn/conflict class being deleted);
prune-on-sync (turns every push destructive and creates non-monotonic reads
mid-review).

Note: the planning documents call this change "reverses"; the ADR uses
`change_type: deprecates` because `reverses` is not in the change_type enum
(`specled.decision.change_type_enum_v1`) and the committed-state requirements
are going away, which is exactly `deprecates`.

## Consequences

- Positive: spec-touching PRs show only human-authored spec edits; rebases
  with unchanged content keep valid evidence (tree hashes are SHA-stable);
  the entire regenerate-post-rebase ceremony class is deleted; base
  comparisons stop inheriting stale-parser skew.
- Positive: concurrent agents in worktrees share evidence instantly (common
  object store) and never lose writes (CAS + per-entry isolation).
- Negative: evidence for a tree exists only if `mix spec.check` ran on
  exactly that content — editing between check and commit yields a commit
  without evidence (soft degradation, heals on next run). Fresh clones and
  forks without the orphan ref get the degraded non-differential review path.
- Negative: across a parser upgrade, finding kinds only the new parser emits
  transiently classify as "introduced" until base evidence refreshes
  (self-healing via last-write-wins).
- The local write path is part of `mix spec.check`: after validation and
  branch-aware co-change enforcement complete, the task writes a plumbing-only
  local attestation and treats write failure as a warning rather than a gate.
- Migration is one-shot per adopted repo; pre-migration history is not
  backfilled and degrades softly forever.
