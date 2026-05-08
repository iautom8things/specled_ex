---
id: specled.decision.realized_by_tier_implication
status: accepted
date: 2026-05-07
affects:
  - specled.realized_by
  - specled.api_boundary
  - specled.implementation_tier
  - specled.binding
  - specled.mix_tasks
  - specled.branch_guard
change_type: extends
---

# `realized_by` Tier Implication and Bare-Module Union Hashing

## Context

Authors hard-couple a spec to its code by listing the same MFAs under both
`realized_by.api_boundary` and `realized_by.implementation`. The duplication
is informationally redundant — the implementation tier's hash input strictly
subsumes the api_boundary tier's for the same MFA — and it is a drift hazard
in its own right when the two lists fall out of sync.

Compounding this: bare-module entries under either tier are silent no-ops
today. The parser accepts them, `Binding.resolve/2` returns
`{:ok, {:module, _}}`, and the detectors return zero findings. Real specs
(e.g., `branch_guard.spec.md` listing `SpecLedEx.Coverage` and
`SpecLedEx.Config.BranchGuard` under `implementation`) contain bare-module
entries the authors believe are tracked, and aren't.

The product question: how should `realized_by` express "I want both kinds of
drift findings on this entry," and how should bare-module entries become
real signal without becoming a footgun?

## Decision

1. **Implication.** Establish a one-way implication
   `implementation` ⟹ `api_boundary` for the same MFA or bare module.
   The implication is realized inside
   `SpecLedEx.Realization.EffectiveBinding.expand_implications/1`, a pure
   idempotent function that the orchestrator applies to each binding map at
   the per-layer site (subject and per-requirement) before bindings are
   accumulated into per-tier flat lists. An entry listed only under
   `api_boundary` does NOT participate in `implementation`-tier semantics.
   The implication scope is exactly this pair — `expanded_behavior`, `use`,
   and `typespecs` remain orthogonal.

2. **Bare-module hashing.** A bare-module entry `Mod` produces:
   - **api_boundary**: `Canonical.hash_module_head_union(Mod)` — a canonical
     hash over the union of public function and macro HEAD ASTs, sorted
     deterministically by `{kind, name, arity}`.
   - **implementation**: `Canonical.hash_module_full_union(Mod)` — the same
     shape over FULL canonical ASTs (head + body + guards).
   Each envelope carries a distinct tag (`:__module_head_union__` vs
   `:__module_full_union__`) so the two tier hashes for the same module
   are guaranteed distinct bytes even on a degenerate module.

3. **Runtime-only bare-module discovery.**
   `Canonical.discover_module_exports/2` enumerates exports via
   `Module.__info__/1` (runtime). When `Code.ensure_loaded/1` returns
   `:error`, the helper returns `{:error, :not_loadable}` and the detector
   emits `branch_guard_dangling_binding` for the bare-module entry tagged
   with the tier the author wrote. Source-AST fallback is **not** used for
   bare-module discovery. This is a deliberate weakening of cross-repo
   determinism for bare-module entries only — a fresh repo running
   `mix spec.check` before `mix compile` produces dangling, not a silent
   seed of a stale source-AST hash that would diverge from the warm-runtime
   shape.

4. **No closure walk from bare-module entries.** Helpers and callees
   reachable only through a bare-module entry do not flow into the hash.
   The closure walker continues to seed from MFA-form entries as today.

5. **Silent seed.** When a tracked entry has no committed hash in
   `.spec/state.json`, the orchestrator computes the hash, persists it via
   the new `SpecLedEx.Realization.HashStore.merge/2` (additive deep-merge,
   in contrast to `write/2`'s replacement semantics), and emits no drift
   finding for that entry on the seeding run. The seed pass runs before
   tier dispatch and is gated by the same conditions as
   `refresh_and_commit_hashes/3`. Dangling entries are not seeded.

6. **Drift / dangling asymmetry.** Drift findings fire on both tiers when
   an implication-bearing MFA's head changes; body-only changes only fire
   the `tier=implementation` finding. Dangling fires once, tagged with the
   tier the author wrote — the api_boundary detector consults the new
   `binding_ref.inferred?` field to suppress the duplicate dangling finding
   on inferred entries. The flag does not appear on any finding map.

7. **Validator + dedup task.** `mix spec.validate` emits
   `realized_by_redundant_dup` (severity `warning`, hardcoded — no config
   plumbing in v1) for any subject where the same entry appears in both
   tiers. The new `mix spec.dedup_realized_by` task prints proposed YAML
   edits removing the redundant `api_boundary` line. Both surfaces share
   `SpecLedEx.Validator.RealizedByDedupe.duplicates/1` so they cannot
   disagree.

## Rejected Alternatives

- **Closure walk from bare-module entries.** Silent fan-out as authors add
  helpers is a footgun for agents; bounded predictable hashing wins.
- **Full lattice across all five tiers.** Other tiers don't have nested
  hash inputs; only `implementation` ⟹ `api_boundary` has a strict
  subsumption invariant.
- **Hard-error rejection of redundant duplications.** Breaks upgrade paths
  for existing specs (`binding.spec.md`, `mix_tasks.spec.md`); warning +
  dedup proposal preserves permissive parsing.
- **`--write` flag on `mix spec.dedup_realized_by`.** Consistent with
  `mix spec.suggest_binding`'s proposal-only stance; agents apply edits.
- **In-place merge inside `EffectiveBinding.for_requirement/2`.** Tangles
  per-requirement inheritance with cross-tier implication. Kept separate
  for separation of concerns.
- **Source-AST fallback for bare-module discovery.** Source AST is
  pre-`use`-expansion; it would silently miss macro-injected functions,
  producing a hash that diverges from the warm-runtime shape on the first
  warm run after `mix compile` — a guaranteed phantom-drift trap. Replaced
  by the explicit dangling outcome in Decision 3.
- **Per-finding `inferred: true` tag.** No consumer needs it; risks
  `Drift.dedupe` complications. The orchestrator-internal `inferred?`
  field is the minimum surface for the dangling-suppression rule.
- **Single `Canonical.hash_module_union(mod, mode: :head | :full)` with a
  flag.** Different normalization per mode; two named functions read
  better at call sites and let each share its normalization with the
  existing tier code (`canonicalize_head/1` for api_boundary,
  `implementation_ast/1` for implementation).
- **Courtesy summary as a v1 must-have.** Dropped the
  `note: seeded N hashes …` operator log line and the
  `Orchestrator.run_with_metadata/2` wrapper it would have required.
  `git diff .spec/state.json` shows what got pulled in. Deferred to v1.1.

## Consequences

- **Positive:** authors stop duplicating MFAs across tiers; bare-module
  entries become a real signal; the silent seed makes upgrade quiet;
  `Drift.dedupe` is unaffected (each tier still produces its own finding).
- **Positive:** the implication seam lives in one place
  (`expand_implications/1`), so detectors don't each re-implement the
  rule.
- **Negative:** the cross-repo determinism guarantee for bare-module
  entries is restricted to "with `mix compile` having run." Cold first
  runs produce dangling. MFA-form entries are unaffected (their per-MFA
  source extraction via `Binding.extract_from_source/3` continues to
  work).
- **Negative:** macro-bearing modules tracked as bare modules will
  drift-fire on macro additions, which is correct but may be surprising
  in macro-heavy modules. Authors who don't want macro drift should list
  specific MFAs instead.
- **Known performance lever (non-blocking):** per-run memoization of
  `hash_module_*_union/2` keyed by `mod` is a v1.1 follow-up if benchmarks
  show pain. v1 recomputes per call site.
