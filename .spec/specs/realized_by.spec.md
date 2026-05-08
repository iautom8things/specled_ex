# Realized-By Bindings

Authored bindings that attach specs to code through named tiers.

## Intent

A `realized_by` declaration is an authored, typed pointer from a spec subject (or an
individual requirement) to the code that realizes it: modules, MFAs, `@behaviour`
conformance, typespecs, `use` consumers. Requirement-level bindings override the
subject-level binding for that requirement only; the merge is explicit so an agent
reading state can tell where a reference came from.

```yaml spec-meta
id: specled.realized_by
kind: module
status: active
summary: zoi schema for `realized_by` on spec-meta and requirement-level overrides; EffectiveBinding merges subject and requirement bindings for a given requirement.
surface:
  - lib/specled_ex/schema/realized_by.ex
  - lib/specled_ex/schema/meta.ex
  - lib/specled_ex/schema/requirement.ex
  - lib/specled_ex/parser.ex
  - lib/specled_ex/realization/effective_binding.ex
  - lib/specled_ex/config/realization.ex
  - test/specled_ex/parser_test.exs
  - test/specled_ex/realization/effective_binding_test.exs
realized_by:
  api_boundary:
    - "SpecLedEx.Schema.RealizedBy.validate/1"
    - "SpecLedEx.Realization.EffectiveBinding.for_requirement/2"
    - "SpecLedEx.Realization.EffectiveBinding.expand_implications/1"
  implementation:
    - "SpecLedEx.Schema.normalize_realized_by/1"
    - "SpecLedEx.Schema.maybe_normalize_realized_by/2"
    - "SpecLedEx.Realization.EffectiveBinding.expand_implications/1"
    - "SpecLedEx.Realization.Canonical.hash_module_head_union/2"
    - "SpecLedEx.Realization.Canonical.hash_module_full_union/2"
    - "SpecLedEx.Realization.HashStore.merge/2"
    - "SpecLedEx.Validator.RealizedByDedupe.duplicates/1"
    - "SpecLedEx.Validator.RealizedByDedupCheck.findings/2"
decisions:
  - specled.decision.realized_by_tier_implication
```

## Requirements

```yaml spec-requirements
- id: specled.realized_by.schema_shape
  statement: >-
    SpecLedEx.Schema.RealizedBy shall define a zoi schema with the keys
    `api_boundary`, `implementation`, `expanded_behavior`, `use`, and
    `typespecs`. Each key is optional; values are lists of MFAs (string
    form `"Mod.fun/arity"`) or module atoms per tier semantics. Unknown
    keys cause a parse error naming the offending key.
  priority: must
  stability: evolving
- id: specled.realized_by.meta_field
  statement: >-
    SpecLedEx.Schema.Meta shall accept an optional `realized_by` field
    whose value is validated by the RealizedBy schema. A meta block
    without `realized_by` shall continue to parse unchanged.
  priority: must
  stability: evolving
- id: specled.realized_by.requirement_override
  statement: >-
    SpecLedEx.Schema.Requirement shall accept an optional `realized_by`
    field whose value overrides the subject-level binding for that
    requirement only, tier by tier. Tiers not set on the requirement
    inherit the subject binding.
  priority: must
  stability: evolving
- id: specled.realized_by.effective_binding_inherits_subject
  statement: >-
    When a requirement declares no `realized_by` tiers, EffectiveBinding.
    for_requirement/2 shall return the subject-level binding verbatim
    for every tier the subject declares, and shall omit tiers the
    subject does not declare.
  priority: must
  stability: evolving
- id: specled.realized_by.effective_binding_requirement_replaces_tier
  statement: >-
    When a requirement declares a `realized_by` value for a tier, that
    value shall replace (not merge into) the subject-level value for
    that tier in the returned binding, while tiers the requirement does
    not set fall through to the subject value.
  priority: must
  stability: evolving
- id: specled.realized_by.effective_binding_accepts_subject_shape
  statement: >-
    EffectiveBinding.for_requirement/2 shall accept three input shapes
    for the subject argument: a parsed schema struct, a plain map with a
    top-level `:realized_by` / `"realized_by"` key, or a parsed-subject
    map (the shape produced by `SpecLedEx.Parser`) where `realized_by`
    lives under `meta.realized_by`. When both a top-level binding and a
    nested `meta.realized_by` are present, the top-level value shall
    win. See `specled.decision.effective_binding_subject_meta_extraction`.
  priority: must
  stability: evolving
- id: specled.realized_by.existing_surface_coexists
  statement: >-
    The existing `spec-meta.surface` field shall continue to parse and
    be available to consumers alongside `realized_by`. v1 shall not
    auto-migrate surface to realized_by; the optional
    mix spec.migrate_surface task, if shipped, is opt-in.
  priority: should
  stability: evolving
- id: specled.realized_by.implication_one_way
  statement: >-
    `SpecLedEx.Realization.EffectiveBinding.expand_implications/1` shall
    apply a one-way implication: every entry (MFA or bare module) listed
    under `implementation` shall also participate in `api_boundary`-tier
    hashing and finding emission. An entry listed only under
    `api_boundary` shall NOT participate in `implementation`-tier
    semantics. The implication scope is exactly this pair —
    `expanded_behavior`, `use`, and `typespecs` shall remain orthogonal.
  priority: must
  stability: evolving
- id: specled.realized_by.implication_invoked_per_layer
  statement: >-
    The orchestrator shall apply
    `EffectiveBinding.expand_implications/1` to each binding map at the
    point it is extracted from a subject or a requirement (per-layer),
    before bindings are accumulated into per-tier flat lists. The
    function is pure and idempotent (calling it twice produces the same
    result). It dedupes the resulting `api_boundary` list and sorts it
    deterministically.
  priority: must
  stability: evolving
- id: specled.realized_by.implication_drift_both_tiers
  statement: >-
    When the head of an implication-bearing MFA changes,
    `mix spec.check` shall emit two `branch_guard_realization_drift`
    findings for the same MFA — one with `tier=api_boundary` and one
    with `tier=implementation`.
  priority: must
  stability: evolving
- id: specled.realized_by.implication_body_only_drift
  statement: >-
    When only the body of an implication-bearing MFA changes and its
    public head is unchanged, `mix spec.check` shall emit only the
    `tier=implementation` drift finding and shall not emit a
    `tier=api_boundary` drift finding for that MFA.
  priority: must
  stability: evolving
- id: specled.realized_by.implication_dangling_once
  statement: >-
    When an implication-bearing MFA cannot be resolved by
    `Binding.resolve/2`, exactly one `branch_guard_dangling_binding`
    finding shall be emitted, tagged with the tier the author wrote
    (`implementation`). The api_boundary detector shall suppress the
    dangling finding for entries whose `binding_ref.inferred?` is true.
  priority: must
  stability: evolving
- id: specled.realized_by.implication_amplification_dedup
  statement: >-
    When the same MFA is declared under `implementation` at both the
    subject layer and a requirement layer (after per-layer expansion),
    the orchestrator shall produce exactly one `api_boundary` binding
    entry for that MFA via post-concat deduplication on the flat
    `api_boundary` binding list (`Enum.uniq_by(& &1.mfa)`). This shall
    not affect other tiers.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_api_boundary_hash
  statement: >-
    A bare-module entry `Mod` listed under `api_boundary` (directly or
    via the implication) shall produce a single hash computed as
    `Canonical.hash_module_head_union(Mod)`: the canonical hash of a
    `{:__module_head_union__, mod, sorted_exports}` envelope where each
    entry is `{kind, name, arity, head_ast}`, `kind` is `:function` or
    `:macro`, and `sorted_exports` is sorted lexicographically by
    `{kind, name, arity}`. A drift finding shall fire on any
    public-head change.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_implementation_hash
  statement: >-
    A bare-module entry `Mod` listed under `implementation` shall
    produce a single hash computed as
    `Canonical.hash_module_full_union(Mod)`: the canonical hash of a
    `{:__module_full_union__, mod, sorted_exports}` envelope where each
    entry is `{kind, name, arity, full_ast}` (head + body + guards).
    The envelope tag differs from the head-union tag so api_boundary
    and implementation hashes for the same module are distinct bytes
    even on a degenerate module.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_drift_after_seed
  statement: >-
    After bare-module hashes have been silently seeded, a subsequent
    body-only change inside the module shall emit exactly one
    `branch_guard_realization_drift` finding with `tier=implementation`
    and shall not emit an api_boundary drift finding for that body-only
    change.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_export_drift
  statement: >-
    After bare-module hashes have been committed, adding a new public
    export shall change both the head-union and full-union hashes and
    shall emit drift findings on both the api_boundary and
    implementation tiers.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_no_closure_walk
  statement: >-
    Bare-module entries under `implementation` shall NOT seed the
    closure walk. Helpers and callees reachable only through a
    bare-module entry shall not flow into the implementation hash.
    MFA-form entries under `implementation` shall continue to seed the
    closure walk as today.
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_runtime_only_discovery
  statement: >-
    `Canonical.discover_module_exports/2` shall enumerate a module's
    public functions and macros via runtime introspection
    (`Module.__info__/1`). When `Code.ensure_loaded/1` returns
    `:error`, the helper shall return `{:error, :not_loadable}` and the
    detector shall emit `branch_guard_dangling_binding` for the
    bare-module entry tagged with the tier the author wrote.
    Source-AST fallback is not used for bare-module discovery (this
    deliberately weakens cross-repo determinism for bare modules to
    avoid silently seeding hashes that diverge from the warm-runtime
    shape).
  priority: must
  stability: evolving
- id: specled.realized_by.bare_module_export_filtering
  statement: >-
    `Canonical.discover_module_exports/2` shall exclude
    `module_info/0` and `module_info/1` (BEAM-injected, not author
    surface) from the export list. `__struct__/0` and `__struct__/1`
    (from `defstruct`) shall be included.
  priority: must
  stability: evolving
- id: specled.realized_by.silent_seed
  statement: >-
    On `mix spec.check`, when a tracked entry (MFA or bare module, in
    any flat tier or implementation tier) has no committed hash in
    `.spec/state.json`, the orchestrator shall compute the entry's
    hash, persist it via `SpecLedEx.Realization.HashStore.merge/2`,
    and emit no drift finding for that entry on the seeding run. The
    seeding pass shall run before tier dispatch and shall be gated by
    the same `commit_hashes? != false` and `umbrella? == false`
    conditions that gate `refresh_and_commit_hashes/3`. Dangling
    entries shall not be seeded.
  priority: must
  stability: evolving
- id: specled.realized_by.silent_seed_uses_merge
  statement: >-
    `SpecLedEx.Realization.HashStore.merge/2` shall deep-merge per-tier
    seed entries into the existing realization map, preserving
    non-seeded entries; `write/2` shall keep its existing replacement
    semantics for the post-run `refresh_and_commit_hashes/3` path.
  priority: must
  stability: evolving
- id: specled.realized_by.redundant_dup_warning
  statement: >-
    `mix spec.validate` shall emit a `realized_by_redundant_dup`
    warning for any subject where the same entry (MFA or bare module)
    appears in both `api_boundary` and `implementation`. The finding
    shall name the subject, the entry, and a one-line remediation
    pointer. The severity shall be `warning` (hardcoded). The
    warning shall use distinct message text for MFA-form vs
    bare-module-form duplications: MFA form notes that api_boundary's
    hash is a strict subset of implementation's; bare-module form
    notes that both tiers continue to track the module via separate
    head-union vs full-union hashes.
  priority: must
  stability: evolving
- id: specled.realized_by.dedup_check_shared_seam
  statement: >-
    The validator's duplication check and the `mix spec.dedup_realized_by`
    task shall both call `SpecLedEx.Validator.RealizedByDedupe.duplicates/1`
    so that the two cannot disagree on edge cases. The shared helper
    shall trim each entry string before computing the intersection.
  priority: must
  stability: evolving
- id: specled.realized_by.binding_ref_inferred_no_leak
  statement: >-
    The new `inferred?` boolean field on a `binding_ref` shall be
    consulted only by the api_boundary detector for dangling-finding
    suppression. It shall not appear on any finding map produced by
    any detector.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.realized_by.scenario.subject_binding_inherits
  given:
    - "a subject with spec-meta `realized_by.api_boundary: [\"MyMod.a/1\", \"MyMod.b/2\"]`"
    - a requirement on that subject with no `realized_by` field
  when:
    - EffectiveBinding.for_requirement/2 is called for that requirement
  then:
    - "the returned map has `api_boundary: [\"MyMod.a/1\", \"MyMod.b/2\"]`"
    - no other tier keys are present
  covers:
    - specled.realized_by.effective_binding_inherits_subject
- id: specled.realized_by.scenario.requirement_override_replaces_tier
  given:
    - "a subject with `realized_by.api_boundary: [\"MyMod.a/1\"]` and `realized_by.implementation: [\"MyMod.a/1\"]`"
    - "a requirement with `realized_by.api_boundary: [\"MyMod.c/3\"]` only"
  when:
    - EffectiveBinding.for_requirement/2 is called
  then:
    - "the returned map has `api_boundary: [\"MyMod.c/3\"]`"
    - "the returned map has `implementation: [\"MyMod.a/1\"]`"
  covers:
    - specled.realized_by.requirement_override
    - specled.realized_by.effective_binding_requirement_replaces_tier
- id: specled.realized_by.scenario.subject_shape_meta_nested
  given:
    - "a parsed-subject map with `meta.realized_by.implementation: [\"A.a/1\"]` and no top-level `realized_by`"
    - "a requirement on that subject with no `realized_by` field"
  when:
    - EffectiveBinding.for_requirement/2 is called for that requirement
  then:
    - "the returned map has `implementation: [\"A.a/1\"]`"
    - "no other tier keys are present"
  covers:
    - specled.realized_by.effective_binding_accepts_subject_shape
- id: specled.realized_by.scenario.unknown_tier_rejected
  given:
    - "a subject with `realized_by.shenanigans: [\"Foo\"]`"
  when:
    - the parser runs on that subject file
  then:
    - "parsing fails with an error that names `shenanigans` and the subject file"
  covers:
    - specled.realized_by.schema_shape
- id: specled.realized_by.scenario.implication_drift_both_tiers
  given:
    - "a subject whose spec lists `Foo.bar/1` only under `realized_by.implementation`"
    - "a hash for `Foo.bar/1` already committed in `.spec/state.json` for both `api_boundary` and `implementation`"
  when:
    - "another developer changes the argument pattern in `Foo.bar/1`'s clause head"
    - "`mix spec.check` runs"
  then:
    - "exactly two `branch_guard_realization_drift` findings name `Foo.bar/1`"
    - "one finding has `tier=api_boundary`; the other has `tier=implementation`"
  covers:
    - specled.realized_by.implication_one_way
    - specled.realized_by.implication_drift_both_tiers
- id: specled.realized_by.scenario.implication_body_only_drift
  given:
    - "a subject whose spec lists `Foo.bar/1` only under `realized_by.implementation`"
    - "the api_boundary head-only hash and the implementation full-AST hash are committed"
  when:
    - "the body of `Foo.bar/1` changes but the head does not"
    - "`mix spec.check` runs"
  then:
    - "exactly one `branch_guard_realization_drift` finding fires"
    - "the finding has `tier=implementation`"
    - "no `tier=api_boundary` drift finding fires for `Foo.bar/1`"
  covers:
    - specled.realized_by.implication_body_only_drift
- id: specled.realized_by.scenario.existing_duplication_validator_warns
  given:
    - "a subject lists `MyMod.foo/1` under both `realized_by.api_boundary` and `realized_by.implementation`"
  when:
    - "`mix spec.validate` runs"
  then:
    - "exactly one `realized_by_redundant_dup` warning fires for the subject"
    - "the finding names `MyMod.foo/1` and points to `mix spec.dedup_realized_by`"
    - "drift behavior is unchanged because the implication still tracks the entry under api_boundary"
  covers:
    - specled.realized_by.redundant_dup_warning
- id: specled.realized_by.scenario.bare_module_first_run_silent_seed
  given:
    - "a subject lists `\"SpecLedEx.Coverage\"` (bare module) under `realized_by.implementation`"
    - "no committed hash for `SpecLedEx.Coverage` exists in `.spec/state.json` for either tier"
  when:
    - "`mix spec.check` runs for the first time after the upgrade"
  then:
    - "`Canonical.hash_module_full_union(SpecLedEx.Coverage)` is computed and persisted under `implementation`"
    - "`Canonical.hash_module_head_union(SpecLedEx.Coverage)` is computed and persisted under `api_boundary` via the implication"
    - "no drift findings are emitted for `SpecLedEx.Coverage`"
  covers:
    - specled.realized_by.silent_seed
    - specled.realized_by.silent_seed_uses_merge
- id: specled.realized_by.scenario.bare_module_drift_after_seed
  given:
    - "the bare-module hashes from the prior scenario are committed"
  when:
    - "a public function inside `SpecLedEx.Coverage` is changed (head or body)"
    - "`mix spec.check` runs"
  then:
    - "a `branch_guard_realization_drift` finding fires with `tier=implementation` naming `SpecLedEx.Coverage`"
    - "if the change touched a function head, an additional `tier=api_boundary` drift finding fires; otherwise only the implementation drift fires"
  covers:
    - specled.realized_by.bare_module_drift_after_seed
- id: specled.realized_by.scenario.bare_module_export_added
  given:
    - "a subject lists `SomeMod` (bare module) under `realized_by.implementation`"
    - "the bare-module union hashes are committed"
  when:
    - "a new public function `SomeMod.new_thing/0` is added"
    - "`mix spec.check` runs"
  then:
    - "drift findings fire on both tiers (the union changed because the export set grew)"
  covers:
    - specled.realized_by.bare_module_export_drift
- id: specled.realized_by.scenario.dangling_implication_once
  given:
    - "a subject lists `Foo.bar/1` only under `realized_by.implementation`"
    - "`Foo.bar/1` does not exist in the codebase"
  when:
    - "`mix spec.check` runs"
  then:
    - "exactly one `branch_guard_dangling_binding` finding fires"
    - "the finding has `tier=implementation`"
    - "no api_boundary dangling finding fires for the inferred entry"
  covers:
    - specled.realized_by.implication_dangling_once
- id: specled.realized_by.scenario.bare_module_not_loadable_dangles
  given:
    - "a subject lists `\"NotLoadable.Module\"` under `realized_by.implementation`"
    - "`Code.ensure_loaded(NotLoadable.Module)` returns `:error`"
  when:
    - "`mix spec.check` runs"
  then:
    - "a `branch_guard_dangling_binding` finding fires for the bare module with `tier=implementation`"
    - "no silent seed of a stale source-AST hash occurs"
  covers:
    - specled.realized_by.bare_module_runtime_only_discovery
- id: specled.realized_by.scenario.implication_amplification_dedup
  given:
    - "a subject's `spec-meta.realized_by.implementation` lists `Foo.bar/1`"
    - "a requirement on the same subject also lists `Foo.bar/1` under `realized_by.implementation`"
  when:
    - "the orchestrator collects bindings and runs the api_boundary detector"
  then:
    - "the post-concat `api_boundary` flat list contains exactly one entry for `Foo.bar/1`"
    - "exactly one `branch_guard_realization_drift` (`tier=api_boundary`) finding fires when the head changes"
  covers:
    - specled.realized_by.implication_amplification_dedup
- id: specled.realized_by.scenario.inferred_flag_does_not_leak
  given:
    - "any spec scenario that produces detector findings"
  when:
    - "the orchestrator returns its findings list"
  then:
    - "no finding map contains a key `inferred?` or `\"inferred?\"`"
  covers:
    - specled.realized_by.binding_ref_inferred_no_leak
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.realized_by.schema_shape
    - specled.realized_by.meta_field
    - specled.realized_by.requirement_override
    - specled.realized_by.existing_surface_coexists
- kind: tagged_tests
  execute: true
  covers:
    - specled.realized_by.effective_binding_inherits_subject
    - specled.realized_by.effective_binding_requirement_replaces_tier
    - specled.realized_by.effective_binding_accepts_subject_shape
- kind: tagged_tests
  execute: false
  covers:
    - specled.realized_by.implication_one_way
    - specled.realized_by.implication_invoked_per_layer
    - specled.realized_by.implication_drift_both_tiers
    - specled.realized_by.implication_body_only_drift
    - specled.realized_by.implication_dangling_once
    - specled.realized_by.implication_amplification_dedup
- kind: tagged_tests
  execute: false
  covers:
    - specled.realized_by.bare_module_api_boundary_hash
    - specled.realized_by.bare_module_implementation_hash
    - specled.realized_by.bare_module_drift_after_seed
    - specled.realized_by.bare_module_export_drift
    - specled.realized_by.bare_module_no_closure_walk
    - specled.realized_by.bare_module_runtime_only_discovery
    - specled.realized_by.bare_module_export_filtering
- kind: tagged_tests
  execute: false
  covers:
    - specled.realized_by.silent_seed
    - specled.realized_by.silent_seed_uses_merge
- kind: tagged_tests
  execute: false
  covers:
    - specled.realized_by.redundant_dup_warning
    - specled.realized_by.dedup_check_shared_seam
- kind: tagged_tests
  execute: false
  covers:
    - specled.realized_by.binding_ref_inferred_no_leak
```
