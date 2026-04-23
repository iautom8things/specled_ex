# Compiler Context

Shared DI struct carrying the compile-time inputs every realization orchestrator needs.

## Intent

Without a context struct, each orchestrator reaches into `Mix.env()`,
`Mix.Project.config()`, or `_build/` to fetch compile manifests and xref graphs. That
is hostile to tests (fixtures need their own build paths) and fragile (implicit
reads from the outer project state contaminate fixture compiles). `%SpecLedEx.Compiler.Context{}`
is the one struct every tier orchestrator accepts as an argument. Production builds it
once via `Context.load/1`; tests construct it with fixture paths.

```yaml spec-meta
id: specled.compiler_context
kind: module
status: active
summary: Carries manifest, xref_graph, tracer_table, and compile_path — every realization orchestrator accepts this as an argument rather than reaching into Mix globals.
surface:
  - lib/specled_ex/compiler/context.ex
  - lib/specled_ex/compiler/manifest.ex
  - test/specled_ex/compiler/manifest_test.exs
  - test/specled_ex/compiler/manifest_integration_test.exs
decisions:
  - specled.decision.compiler_context_di
```

## Requirements

```yaml spec-requirements
- id: specled.compiler_context.struct_shape
  statement: >-
    SpecLedEx.Compiler.Context shall be a struct with fields
    `manifest`, `xref_graph`, `tracer_table`, and `compile_path`. Each
    field is nillable only during partial construction; fully-loaded
    contexts have every field populated.
  priority: must
  stability: evolving
- id: specled.compiler_context.load_from_opts
  statement: >-
    Context.load/1 shall accept an options keyword with `app:`, `env:`,
    and `build_path:`. It shall NOT consult Mix.Project.config/0 or
    Mix.env/0 internally — all inputs are explicit. Defaults are the
    caller's responsibility.
  priority: must
  stability: evolving
- id: specled.compiler_context.manifest_wraps_stdlib
  statement: >-
    SpecLedEx.Compiler.Manifest.load/1 shall delegate to
    `Mix.Compilers.Elixir.read_manifest/1` for reading the compile
    manifest. No custom binary parser shall be shipped. If a future
    Elixir minor version changes the manifest format, failure shall
    surface as a test error, not a silent misread.
  priority: must
  stability: evolving
- id: specled.compiler_context.manifest_fixture_integration
  statement: >-
    A `:integration`-tagged test shall exercise Manifest.load/1
    against a real `test/fixtures/sample_project/` compile, asserting
    the returned map contains at least one module entry whose
    `sources` list is non-empty. This is the canary for minor-version
    format drift.
  priority: must
  stability: evolving
- id: specled.compiler_context.orchestrators_take_context
  statement: >-
    Every module under `SpecLedEx.Realization.*` and
    `SpecLedEx.CoverageTriangulation` whose public functions need
    compile inputs shall accept a `%Context{}` as a positional
    argument. Grep for `Mix.Project.config(` or `Mix.env(` inside
    those modules shall return zero hits after S2.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.compiler_context.scenario.load_with_explicit_paths
  given:
    - "a call `Context.load(app: :sample_project, env: :test, build_path: \"_build\")`"
  when:
    - the call returns
  then:
    - "the returned `%Context{}` has `compile_path` set from build_path + env + app"
    - "the returned `%Context{}` has a populated `manifest`"
    - "no Mix global state was consulted"
  covers:
    - specled.compiler_context.load_from_opts
    - specled.compiler_context.struct_shape
- id: specled.compiler_context.scenario.manifest_integration_smoke
  given:
    - test/fixtures/sample_project/ compiled once by setup_all
  when:
    - Manifest.load/1 is called with the fixture's build path
  then:
    - "the returned map contains at least one `{module, {:module, _, sources, _, _, _}}` entry"
    - sources for some module is non-empty
  covers:
    - specled.compiler_context.manifest_wraps_stdlib
    - specled.compiler_context.manifest_fixture_integration
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/compiler/manifest_test.exs
  execute: true
  covers:
    - specled.compiler_context.struct_shape
    - specled.compiler_context.load_from_opts
    - specled.compiler_context.manifest_wraps_stdlib
- kind: command
  target: mix test test/specled_ex/compiler/manifest_integration_test.exs --include integration
  execute: true
  covers:
    - specled.compiler_context.manifest_fixture_integration
- kind: source_file
  target: lib/specled_ex/realization/api_boundary.ex
  execute: true
  covers:
    - specled.compiler_context.orchestrators_take_context
```
