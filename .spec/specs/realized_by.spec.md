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
- id: specled.realized_by.existing_surface_coexists
  statement: >-
    The existing `spec-meta.surface` field shall continue to parse and
    be available to consumers alongside `realized_by`. v1 shall not
    auto-migrate surface to realized_by; the optional
    mix spec.migrate_surface task, if shipped, is opt-in.
  priority: should
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
- id: specled.realized_by.scenario.unknown_tier_rejected
  given:
    - "a subject with `realized_by.shenanigans: [\"Foo\"]`"
  when:
    - the parser runs on that subject file
  then:
    - "parsing fails with an error that names `shenanigans` and the subject file"
  covers:
    - specled.realized_by.schema_shape
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/parser_test.exs
  execute: true
  covers:
    - specled.realized_by.schema_shape
    - specled.realized_by.meta_field
    - specled.realized_by.requirement_override
    - specled.realized_by.existing_surface_coexists
- kind: command
  target: mix test test/specled_ex/realization/effective_binding_test.exs
  execute: true
  covers:
    - specled.realized_by.effective_binding_inherits_subject
    - specled.realized_by.effective_binding_requirement_replaces_tier
```
