# Evidence Store (orphan-branch spec-evidence ledger)

Execution evidence for verified snapshots, keyed by tree hash, stored on an
orphan `spec-evidence` branch that is never checked out.

## Intent

`.spec/state.json` mixed regenerable parse cache with irreplaceable execution
evidence. This subject owns the evidence half after the split: per-cover
execution outcomes and the findings list a `mix spec.check` run produced, one
entry per verified tree. The cache half ceases to exist as a committed
artifact (see `specled.decision.evidence_orphan_branch_split`).

Design invariants the modules must hold, in one place: entries are isolated
one-file-per-tree-hash so disjoint writers never touch the same blob; every
same-key conflict — local re-run or sync merge — resolves by the highest run
stamp, so "the newest run is authoritative" is order-independent across
agents; the check-time write path is strictly local (zero network); sync
reconciles by tree content, never history, so independently self-created
orphan roots converge; coordination across OS processes happens exclusively
through git ref compare-and-swap — no locks, no daemons. Evidence is an
unauthenticated attestation: any repo-writer can mint an entry for any tree
hash, so it may inform presentation and advisory review output but never a
pass/fail gate.

```yaml spec-meta
id: specled.evidence_store
kind: module
status: active
summary: Orphan-branch evidence ledger — tree-hash-keyed entries written locally by spec.check, reconciled by mix spec.sync via plumbing-only tree-union merges.
surface:
  - lib/specled_ex/evidence/tree_hash.ex
  - lib/specled_ex/evidence/entry.ex
  - lib/specled_ex/evidence/store.ex
  - lib/specled_ex/evidence/sync.ex
  - lib/specled_ex/evidence/git.ex
  - lib/specled_ex/evidence/warnings.ex
  - lib/mix/tasks/spec.sync.ex
  - lib/mix/tasks/spec.prune.ex
  - lib/mix/tasks/spec.evidence.migrate.ex
  - lib/mix/tasks/spec.evidence.install_hook.ex
  - priv/hooks/pre-push
  - test/specled_ex/evidence/tree_hash_test.exs
  - test/specled_ex/evidence/entry_test.exs
  - test/specled_ex/evidence/store_test.exs
  - test/specled_ex/evidence/sync_test.exs
  - test/specled_ex/evidence/git_test.exs
  - test/test_support/evidence_helpers.ex
  - test/mix/tasks/spec_sync_task_test.exs
  - test/mix/tasks/spec_prune_task_test.exs
decisions:
  - specled.decision.evidence_orphan_branch_split
  - specled.decision.sync_noop_short_circuit_and_auto_prune
```

## Requirements

```yaml spec-requirements
- id: specled.evidence_store.tree_hash_mirrors_add_all
  statement: >-
    The current-tree evidence key shall be computed by mirroring `git add
    -A`: a temporary index seeded from HEAD under a unique per-invocation
    GIT_INDEX_FILE, `git add -A` applied into that index, then `git
    write-tree`. The resulting hash shall equal the `^{tree}` of the commit
    produced by `git add -A && git commit` from the same working-tree state
    (untracked non-ignored files and deletions included, .gitignore
    respected). Base keys resolve via `git rev-parse <ref>^{tree}`.
  priority: must
  stability: evolving
- id: specled.evidence_store.per_entry_isolation
  statement: >-
    Each evidence entry shall be a single file at the root of the evidence
    tree named `<tree_hash>.json`, serialized as canonical JSON with a
    `schema_version` field. Entry filenames shall be validated against
    `^[0-9a-f]{40,64}\.json$` on read; no aggregated multi-entry file may
    exist on the spec-evidence branch.
  priority: must
  stability: evolving
- id: specled.evidence_store.run_stamp_wins
  statement: >-
    Every entry shall carry a run stamp of ISO-8601 UTC `run_at` plus a
    random `run_id` tiebreaker, recorded at check time. Same-key conflicts
    shall resolve by lexicographic comparison on `(run_at, run_id)`, keeping
    the highest — applied identically to local re-run replacement and to the
    sync merge, so resolution is deterministic and order-independent across
    agents.
  priority: must
  stability: evolving
- id: specled.evidence_store.local_cas_bounded
  statement: >-
    Local ref updates shall be compare-and-swap (`git update-ref` with the
    expected old value) with re-read-and-retry on failure, bounded at 5
    attempts. On exhaustion the write fails with a named
    `evidence/local_write_failed` warning and the calling `mix spec.check`
    run's exit status is unaffected — an evidence-write failure never fails
    the verification gate.
  priority: must
  stability: evolving
- id: specled.evidence_store.self_create
  statement: >-
    When no local `spec-evidence` ref exists (fresh clone, unmigrated repo,
    deleted ref), recording an entry shall self-create the orphan ref via a
    parentless commit-tree and write the first entry. Recording is always
    safe to run pre-migration.
  priority: must
  stability: evolving
- id: specled.evidence_store.local_only_write_path
  statement: >-
    The check-time write path (TreeHash, Entry, Store, and the spec.check
    integration) shall perform zero network I/O — no fetch, no push. The
    Sync module is the only network surface of this subject. The orphan ref
    shall never be checked out into any worktree by any code path.
  priority: must
  stability: evolving
- id: specled.evidence_store.sync_tree_union
  statement: >-
    Sync shall reconcile local and remote spec-evidence refs by tree
    content, never history: fetch the remote ref, compute a per-key
    tree-union using plumbing only (disjoint entry paths union; same-path
    entries resolve per the run-stamp rule), `commit-tree` the merged tree,
    then push with `--force-with-lease` pinned to the fetched sha. On lease
    rejection it shall refetch, re-merge, and retry, bounded at 3 attempts.
    Independently self-created orphan roots (no merge base) shall merge by
    the same content-based path. Ledger pushes shall bypass git hooks
    (`--no-verify`): the installed pre-push hook itself invokes `mix
    spec.sync`, so a hook-honoring ledger push would recurse without bound.
  priority: must
  stability: evolving
- id: specled.evidence_store.sync_failure_contracts
  statement: >-
    On retry exhaustion, `mix spec.sync` shall raise (non-zero exit) in
    default mode, and shall emit exactly one well-formed warning and exit 0
    in `--best-effort` mode. Evidence-sync failure never blocks a code push.
  priority: must
  stability: evolving
- id: specled.evidence_store.prune_explicit_only
  statement: >-
    Evidence entries shall be dropped only through one shared reachable-set
    computation — the tree hashes of commits reachable from local branch
    heads and remote-tracking refs after a fetch — never by any other
    deletion path. That computation is invoked explicitly by `mix
    spec.prune`, and automatically by sync's size-threshold trigger (see
    `specled.evidence_store.sync_auto_prune`); either way the pruned tree is
    pushed via the same lease-guarded sync path.
  priority: must
  stability: evolving
- id: specled.evidence_store.prune_reachability_floor
  statement: >-
    Pruning shall never turn a non-empty store into an empty one. A
    keep-set whose application would remove every stored entry is treated
    as a failed computation, whether the set itself is empty (a checkout
    with no non-evidence branch or remote-tracking refs, e.g. detached or
    ref-less CI checkouts) or non-empty but disjoint from every stored
    evidence key (a checkout whose reachable trees intersect none of the
    evidenced trees). In both cases `mix spec.prune` shall refuse with an
    error and leave both refs untouched, and sync's auto-prune shall
    degrade to a plain unpruned merge and surface one
    `evidence/auto_prune_degraded` warning.
  priority: must
  stability: evolving
- id: specled.evidence_store.sync_auto_prune
  statement: >-
    During a real reconciliation (local and remote `spec-evidence` refs
    differ) where no explicit keep-set was supplied, sync shall compare the
    merged entry count against a size threshold; once crossed, it shall
    compute the same reachable-tree-hash keep-set `mix spec.prune` uses and
    apply it to the merged tree before writing and pushing, folding
    retention into the sync hot path without requiring a separate `mix
    spec.prune` invocation. Below the threshold, or when the keep-set
    computation fails, sync shall proceed as a plain unpruned merge rather
    than fail the attempt.
  priority: must
  stability: evolving
- id: specled.evidence_store.sync_bounded_subprocesses
  statement: >-
    A real reconciliation shall read and write entries through batched git
    plumbing: entry reads go through one tree listing plus one batch
    object read per ref, and entry writes through chunked
    `hash-object` / `update-index` invocations, so the total git
    subprocess count for a reconcile is a small constant plus one
    invocation per write chunk — never one or more subprocesses per entry.
  priority: should
  stability: evolving
- id: specled.evidence_store.sync_noop_short_circuit
  statement: >-
    When the fetched remote commit already equals the local `spec-evidence`
    commit and no explicit keep-set was supplied, `Sync.run` shall return
    `action: :noop` (ahead 0, behind 0, no warnings) without performing any
    per-entry read — no tree listing, no blob read, no decode — on either
    ref. The common no-drift outcome the pre-push hook hits on nearly every
    push is O(1) in store size, not O(entries).
  priority: must
  stability: evolving
- id: specled.evidence_store.attestation_never_gates
  statement: >-
    Evidence is an unauthenticated attestation. No pass/fail gate —
    spec.check exit status, weakening guard, CI verdict — shall consume
    evidence-derived classification as an input; enforcement draws from
    live-parsed specs only. Evidence informs presentation and advisory
    review output exclusively, and its consumers degrade softly (never
    error) when an entry is absent.
  priority: must
  stability: evolving
- id: specled.evidence_store.migration_one_shot
  statement: >-
    `mix spec.evidence.migrate` shall, idempotently: hoist any legacy
    embedded realization baseline, seed the orphan ref with evidence for the
    current tree via a fresh check run, untrack `.spec/state.json` with `git
    rm --cached` (preserving the file and its history), append
    `.spec/state.json` to .gitignore, and install the pre-push hook. It
    shall regenerate nothing else and leave `.spec/realization_hashes.json`
    untouched.
  priority: must
  stability: evolving
- id: specled.evidence_store.hook_static_never_blocks
  statement: >-
    `mix spec.evidence.install_hook` shall install a static,
    repo-content-free pre-push shim that runs `mix spec.sync --best-effort`,
    only when no pre-push hook exists; when one exists it shall refuse,
    print the snippet to append, and exit without touching it. The installed
    hook shall never block a code push (warn-and-exit-0 by construction).
  priority: must
  stability: evolving
- id: specled.evidence_store.drift_surfaced
  statement: >-
    `mix spec.sync` output shall surface ahead/behind entry counts relative
    to the last-fetched remote ref, labeled as of the last fetch, so
    evidence drift is visible without being a failure.
  priority: should
  stability: evolving
- id: specled.evidence_store.sync_entry_tolerance
  statement: >-
    Sync shall never halt reconciliation because of a single entry it cannot
    validate. An entry whose path fails the per-entry-isolation filename
    pattern, whose payload does not parse as JSON, whose tree_hash does not
    match its filename, or whose schema_version this build does not
    recognize (older or newer, e.g. a peer running a future specled) shall
    be quarantined: carried through the tree union byte-identical under its
    original path rather than dropped or rewritten, with one warning
    emitted naming the path and reason. All other entries in the same sync
    continue to reconcile normally, and a quarantined path present on both
    sides of a merge resolves deterministically so independently-created
    orphan roots still converge. Tolerance extends to the tree layer: a
    non-blob tree entry (e.g. a crafted gitlink) shall be carried through
    the union byte-identical at the tree level — original mode and object
    id, never read — with one warning, and an entry at a path git refuses
    to stage (`..`, `.git`, empty components) shall be dropped from the
    union with one `evidence/entry_skipped` warning so the store
    self-heals on the next push. Only git-level read failures of the tree
    listing or object database halt reconciliation.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.evidence_store.scenario.check_key_equals_commit_tree
  given:
    - a tmp git repo with a tracked file modified, a new untracked non-ignored file, and a .gitignore'd file
    - a completed mix spec.check run in that repo
  when:
    - "`git add -A && git commit` is executed afterward from the same working-tree state"
  then:
    - the spec-evidence ref exists (self-created) with exactly one entry file
    - "the entry filename stem equals `git rev-parse HEAD^{tree}` of the new commit"
    - the ignored file's content did not influence the key
  covers:
    - specled.evidence_store.tree_hash_mirrors_add_all
    - specled.evidence_store.self_create
- id: specled.evidence_store.scenario.entry_is_isolated_canonical_json
  given:
    - two spec.check runs against two different tree contents in one repo
  when:
    - the evidence tree at the spec-evidence ref tip is listed
  then:
    - "two files exist at the tree root, each named `<tree_hash>.json` matching `^[0-9a-f]{40,64}\\.json$`"
    - "each parses as JSON with schema_version 1, run_at, run_id, verification map, and findings list"
  covers:
    - specled.evidence_store.per_entry_isolation
- id: specled.evidence_store.scenario.same_key_higher_stamp_replaces
  given:
    - "an existing entry for tree T with constructed stamp (2026-07-16T10:00:00.000000Z, aaaa...)"
  when:
    - "an entry for T with stamp (2026-07-16T10:00:00.000000Z, bbbb...) is recorded"
    - "then an entry for T with stamp (2026-07-16T09:00:00.000000Z, ffff...) is recorded"
  then:
    - "after the first record the stored entry's run_id is bbbb... (higher tiebreaker wins)"
    - "after the second record the stored entry is unchanged (lower run_at never replaces)"
  covers:
    - specled.evidence_store.run_stamp_wins
- id: specled.evidence_store.scenario.concurrent_local_writers_both_survive
  given:
    - a spec-evidence ref at commit C
    - "a writer that read C, while a competing writer moved the ref to C' (new entry for tree T2)"
  when:
    - the first writer's CAS update-ref fails and it re-reads and retries recording its entry for tree T1
  then:
    - the final evidence tree contains both T1.json and T2.json
    - no entry was silently dropped
  covers:
    - specled.evidence_store.local_cas_bounded
- id: specled.evidence_store.scenario.check_offline_write_failure_never_gates
  given:
    - a repo with no network access and a ref pinned so CAS fails 5 times (forced contention)
  when:
    - mix spec.check runs with all verification targets passing
  then:
    - "the task emits an `evidence/local_write_failed` warning"
    - the task exit status is 0 and no fetch or push was attempted
  covers:
    - specled.evidence_store.local_only_write_path
- id: specled.evidence_store.scenario.sync_converges_in_both_push_orders
  given:
    - a bare origin repo and two clones A and B
    - "A holds entries {T1: stamp s1} and {T3: stamp s3a}; B holds {T2: stamp s2} and {T3: stamp s3b} where s3b > s3a, with independently self-created orphan roots"
  when:
    - A syncs then B syncs — and separately, B syncs then A syncs (fresh fixtures)
  then:
    - "in both orders the origin evidence tree converges to {T1: s1, T2: s2, T3: s3b}"
    - the second syncer's push succeeded only after a refetch and re-merge (lease rejection path exercised)
    - no worktree ever had the spec-evidence branch checked out
  covers:
    - specled.evidence_store.sync_tree_union
- id: specled.evidence_store.scenario.sync_quarantines_bad_entries
  given:
    - a bare origin repo and two clones A and B
    - "the remote spec-evidence tree holds one valid entry alongside an entry at a non-hash path, an entry with unparsable JSON, and an entry with a future schema_version, all written directly with git plumbing (simulating a foreign tool or a newer peer's specled)"
  when:
    - A syncs against that origin, then B syncs against the result
  then:
    - both syncs complete successfully (no halt) and the valid entry reconciles as usual
    - each malformed or unrecognized entry is present afterward with byte-identical content at its original path
    - "the sync result's warnings list names each quarantined path and its reason"
    - B's sync converges to the same tree A produced without altering the quarantined entries or re-raising
  covers:
    - specled.evidence_store.sync_entry_tolerance
- id: specled.evidence_store.scenario.sync_exhaustion_modes
  given:
    - an origin whose spec-evidence ref is moved by a competing writer before every push attempt (3 consecutive lease rejections)
  when:
    - mix spec.sync runs in default mode, and again with --best-effort
  then:
    - default mode raises with non-zero exit
    - --best-effort emits exactly one warning and exits 0
  covers:
    - specled.evidence_store.sync_failure_contracts
- id: specled.evidence_store.scenario.prune_drops_only_unreachable
  given:
    - entries for tree A (reachable from a local branch head), tree B (reachable only from a remote-tracking ref), and tree C (reachable from no ref)
  when:
    - mix spec.prune runs after a fetch
  then:
    - entries A and B remain; entry C is gone
    - a plain mix spec.sync run below the auto-prune threshold never removed C beforehand
  covers:
    - specled.evidence_store.prune_explicit_only
- id: specled.evidence_store.scenario.sync_auto_prunes_over_threshold
  given:
    - a repo whose evidence holds one entry for a reachable tree and one for an unreachable tree, with no explicit keep-set supplied
  when:
    - a real (non-no-op) sync runs with the auto-prune size threshold set below the merged entry count
  then:
    - the unreachable entry is dropped from the pushed tree using the same reachable-set computation mix spec.prune uses
    - the same setup with the threshold set above the merged entry count leaves the unreachable entry in place
  covers:
    - specled.evidence_store.sync_auto_prune
- id: specled.evidence_store.scenario.prune_refuses_empty_keep_set
  given:
    - a repo holding evidence entries whose only non-evidence refs have been deleted, so the reachable keep-set computes empty
  when:
    - mix spec.prune runs, and separately a real over-threshold sync runs with no explicit keep-set
  then:
    - mix spec.prune raises evidence/prune_refused and every evidence entry survives on both refs
    - the over-threshold sync pushes an unpruned merge and reports one evidence/auto_prune_degraded warning
  covers:
    - specled.evidence_store.prune_reachability_floor
- id: specled.evidence_store.scenario.prune_refuses_disjoint_keep_set
  given:
    - a repo with intact refs whose stored evidence entries are all for trees no ref reaches, so the reachable keep-set is non-empty but matches no stored key
  when:
    - mix spec.prune runs, and separately a real over-threshold sync runs with no explicit keep-set
  then:
    - mix spec.prune raises evidence/prune_refused and every evidence entry survives on both refs
    - the over-threshold sync pushes an unpruned merge and reports one evidence/auto_prune_degraded warning
  covers:
    - specled.evidence_store.prune_reachability_floor
- id: specled.evidence_store.scenario.sync_tolerates_tree_level_corruption
  given:
    - a spec-evidence tree crafted with raw plumbing to hold a gitlink entry and a blob entry at a path git refuses to stage, alongside one valid entry
  when:
    - a real sync reconciles and a peer then adopts the pushed result
  then:
    - the gitlink is carried through byte-identical at the tree level (same mode and object id) with one quarantine warning
    - the unstageable-path entry is dropped from the pushed union with one evidence/entry_skipped warning
    - the valid entry reconciles normally and no peer's sync halts
  covers:
    - specled.evidence_store.sync_entry_tolerance
- id: specled.evidence_store.scenario.sync_reconciles_across_chunk_boundary
  given:
    - a store holding more entries than one write chunk covers
  when:
    - a real sync reconciles and pushes
  then:
    - every entry path on the pushed ref maps to exactly its original encoded content
    - the number of git subprocesses spawned by the reconcile stays under a fixed bound instead of scaling with the entry count
  covers:
    - specled.evidence_store.sync_bounded_subprocesses
- id: specled.evidence_store.scenario.sync_noop_never_reads_an_entry
  given:
    - a repo whose local and remote spec-evidence refs already point at the same commit, which contains a quarantined (invalid-path) entry
  when:
    - mix spec.sync runs again with no explicit keep-set
  then:
    - the result reports action noop, ahead 0, behind 0, and an empty warnings list
    - no quarantine warning is re-emitted for the entry already present in the unchanged tree, proving no entry was re-read
  covers:
    - specled.evidence_store.sync_noop_short_circuit
- id: specled.evidence_store.scenario.evidence_never_gates
  given:
    - a repo where the base tree's evidence entry classifies a live finding as pre-existing
  when:
    - mix spec.check runs with a weakening edit present
  then:
    - the weakening guard's verdict is computed from live-parsed specs only
    - deleting the entire spec-evidence ref does not change any spec.check exit status
  covers:
    - specled.evidence_store.attestation_never_gates
- id: specled.evidence_store.scenario.migrate_then_rerun_noop
  given:
    - a tmp git repo with a committed .spec/state.json and no spec-evidence ref
  when:
    - mix spec.evidence.migrate runs twice
  then:
    - after the first run the orphan ref holds an entry for the current tree, state.json is untracked but present on disk, .gitignore lists it, and .git/hooks/pre-push is the static shim
    - the second run changes nothing (idempotent)
    - .spec/realization_hashes.json is byte-identical before and after
  covers:
    - specled.evidence_store.migration_one_shot
- id: specled.evidence_store.scenario.hook_installer_refuses_existing
  given:
    - a repo with a pre-existing .git/hooks/pre-push containing user content
  when:
    - mix spec.evidence.install_hook runs
  then:
    - the existing hook file is byte-identical afterward
    - the task printed the snippet to append and exited without error
    - in a repo without a hook, the installed shim contains no repo-derived content and exits 0 when mix spec.sync fails
  covers:
    - specled.evidence_store.hook_static_never_blocks
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.evidence_store.tree_hash_mirrors_add_all
    - specled.evidence_store.per_entry_isolation
    - specled.evidence_store.run_stamp_wins
    - specled.evidence_store.local_cas_bounded
    - specled.evidence_store.self_create
    - specled.evidence_store.local_only_write_path
- kind: command
  target: mix test test/specled_ex/evidence/sync_test.exs test/specled_ex/evidence/git_test.exs test/mix/tasks/spec_sync_task_test.exs test/mix/tasks/spec_prune_task_test.exs
  execute: true
  covers:
    - specled.evidence_store.sync_tree_union
    - specled.evidence_store.sync_failure_contracts
    - specled.evidence_store.prune_explicit_only
    - specled.evidence_store.prune_reachability_floor
    - specled.evidence_store.drift_surfaced
    - specled.evidence_store.sync_entry_tolerance
    - specled.evidence_store.sync_auto_prune
    - specled.evidence_store.sync_noop_short_circuit
    - specled.evidence_store.sync_bounded_subprocesses
- kind: tagged_tests
  execute: true
  covers:
    - specled.evidence_store.attestation_never_gates
- kind: command
  target: mix test test/mix/tasks/spec_evidence_migrate_test.exs test/mix/tasks/spec_evidence_install_hook_test.exs
  execute: true
  covers:
    - specled.evidence_store.migration_one_shot
    - specled.evidence_store.hook_static_never_blocks
```

Note for implementing stages: as each test file lands with `@tag spec:`
annotations, convert the covering stub to `kind: tagged_tests` (repo
convention) — or flip `execute: true` on the command form — in the same
stage that adds the tests.
