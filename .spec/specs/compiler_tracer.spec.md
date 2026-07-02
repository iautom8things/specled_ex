# Compile Tracer + Xref Integration

Custom `Code.Tracer` that emits MFA-level callee edges at compile time, plus
in-process DOT xref for file-level classification.

## Intent

Elixir's `mix xref graph --format json` does not exist. A post-hoc call-graph
analyzer would duplicate compiler work and contradict the project's
reuse-over-reinvent rule. The supported seam is `Code.Tracer`: we register our
own tracer in `mix.exs` and write MFA-level callee edges to an ETF side-manifest
at compile completion. The coarse `mix xref graph --format dot --output -` output
serves the compile/exports/runtime edge-kind classification.

```yaml spec-meta
id: specled.compiler_tracer
kind: module
status: active
summary: SpecLedEx.Compiler.Tracer emits `{mod, fun, arity} => [callees]` ETF to `_build/<env>/.spec/xref_mfa.etf` on `:on_module`; Compiler.Xref runs `Mix.Task.run("xref", ["graph","--format","dot","--output","-"])` in-process and parses DOT.
surface:
  - lib/specled_ex/compiler/tracer.ex
  - lib/specled_ex/compiler/xref.ex
  - test/specled_ex/compiler/tracer_test.exs
  - test/specled_ex/compiler/xref_test.exs
  - test/integration/tracer_incremental_merge_test.exs
  - mix.exs
  - test/fixtures/sample_project/mix.exs
  - test/fixtures/sample_project/.gitignore
realized_by:
  api_boundary:
    - "SpecLedEx.Compiler.Tracer.trace/2"
    - "SpecLedEx.Compiler.Xref.load/1"
    - "SpecLedEx.Compiler.Xref.parse/1"
  implementation:
    - "SpecLedEx.Compiler.Tracer.ensure_table/0"
    - "SpecLedEx.Compiler.Tracer.manifest_path/1"
decisions:
  - specled.decision.custom_compile_tracer
```

## Requirements

```yaml spec-requirements
- id: specled.compiler_tracer.captures_remote_calls
  statement: >-
    SpecLedEx.Compiler.Tracer shall implement `trace/2` for the
    `remote_function` and `imported_function` events, accumulating
    `{caller_mfa, callee_mfa}` edges keyed on the calling module/fun/arity.
    On the `:on_module` event, it shall persist the accumulated edges to
    ETF at `_build/<env>/.spec/xref_mfa.etf` by merging with the
    manifest's existing content per
    `specled.compiler_tracer.merge_on_flush`, never by whole-file
    replacement.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.merge_on_flush
  statement: >-
    On `:on_module` the tracer shall write the manifest as a merge: the
    pre-session manifest content, minus entries whose caller module was
    compiled this session, unioned with the session's accumulated edges,
    with callee lists sorted and deduplicated. Writes shall be atomic
    (unique temp file plus rename). The effective edge graph after an
    incremental compile shall equal the graph after a forced full
    compile of the same tree.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.session_module_replacement
  statement: >-
    The set of session-compiled modules shall be tracked from
    `:on_module` events' env, never inferred from edge callers, so a
    recompiled module that captured zero remote-call edges still
    replaces (drops) its stale manifest entries on flush.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.seed_time_ghost_prune
  statement: >-
    The pre-session manifest content shall be read once per compile
    session and, when the project's compile manifest is non-empty,
    pruned of entries whose caller module is absent from it. An empty or
    unreadable compile manifest disables the prune (a cold build must
    not wipe the merge base), and a lag of one compile for deleted
    modules is acceptable — read-time filtering in the implementation
    tier is the authoritative ghost prune.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.registered_in_mix_exs
  statement: >-
    The project `mix.exs` shall register the tracer via
    `elixirc_options: [tracers: [SpecLedEx.Compiler.Tracer]]`. The
    `test/fixtures/sample_project/mix.exs` shall register it identically
    so fixture compiles produce the same manifest shape.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.single_file_cap
  statement: >-
    All tracer logic shall live in a single file
    `lib/specled_ex/compiler/tracer.ex`, and code reachable from
    `trace/2` shall call only `Mix`/stdlib modules — never sibling
    `SpecLedEx.*` modules: the tracer can be reached over a pruned code
    path (a fixture or consumer loading it via `ERL_LIBS`, where Mix's
    compile-time code-path pruning strands any lazily-loaded companion
    module mid-compile; `Mix` itself is resident in every compiling VM).
    Factoring trace-time helpers into `lib/specled_ex/compiler/tracer/`
    is therefore not an option; trim documentation before logic if file
    size becomes a concern.
  priority: should
  stability: evolving
- id: specled.compiler_tracer.xref_in_process
  statement: >-
    SpecLedEx.Compiler.Xref.load/1 shall call
    `Mix.Task.run("xref", ["graph", "--format", "dot", "--output", "-"])`
    in-process and parse the returned DOT into a graph keyed by edge
    kind (`:compile`, `:exports`, `:runtime`). It shall NOT shell out to
    `mix xref` as a subprocess.
  priority: must
  stability: evolving
- id: specled.compiler_tracer.etf_read_direct
  statement: >-
    The tracer side-manifest at `_build/<env>/.spec/xref_mfa.etf` shall
    be read directly from disk via `:erlang.binary_to_term/1`. No
    subprocess invocation shall be used to retrieve MFA edges.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.compiler_tracer.scenario.mfa_edges_emitted
  given:
    - a fixture module containing at least one remote call
    - tracer registered in fixture mix.exs
    - the fixture subprocess's code path includes the parent's tracer beam (via `ERL_LIBS`)
  when:
    - the fixture compiles as a subprocess
  then:
    - "`<fixture>/_build/test/.spec/xref_mfa.etf` exists"
    - the deserialized term is a non-empty map keyed by `{caller_mod, caller_fun, caller_arity}` with at least one entry whose caller module is the fixture's module
  covers:
    - specled.compiler_tracer.captures_remote_calls
    - specled.compiler_tracer.registered_in_mix_exs
- id: specled.compiler_tracer.scenario.incremental_equals_force
  given:
    - a project of three modules where A remote-calls B and B remote-calls C, fully compiled with the tracer registered
  when:
    - one module's source content changes and the project recompiles incrementally
  then:
    - the deserialized manifest equals the manifest produced by a forced full recompile of the same tree from a clean `_build`
  covers:
    - specled.compiler_tracer.merge_on_flush
- id: specled.compiler_tracer.scenario.recompiled_module_replaces_edges
  given:
    - a manifest on disk containing stale entries for module M and entries for module N
    - a compile session in which M recompiles and captures zero remote-call edges
  when:
    - the tracer flushes M via `:on_module`
  then:
    - M's stale entries are absent from the written manifest
    - N's entries are preserved
  covers:
    - specled.compiler_tracer.session_module_replacement
- id: specled.compiler_tracer.scenario.ghost_module_pruned
  given:
    - a manifest on disk containing entries for a module that no longer exists in the project
  when:
    - the project compiles twice after the module's deletion (seed-time pruning lags one compile because the on-disk compile manifest is stale during the deleting compile)
  then:
    - the final manifest contains no entries whose caller is the deleted module
  covers:
    - specled.compiler_tracer.seed_time_ghost_prune
- id: specled.compiler_tracer.scenario.xref_dot_parsed
  given:
    - a compiled Elixir project with inter-file call edges
  when:
    - Compiler.Xref.load/1 is called in-process against the current Mix project
  then:
    - the returned graph is a map keyed by `:compile`, `:exports`, and `:runtime`
    - at least one of those kinds contains edges
    - the function did not spawn a subprocess
  covers:
    - specled.compiler_tracer.xref_in_process
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.compiler_tracer.captures_remote_calls
    - specled.compiler_tracer.registered_in_mix_exs
    - specled.compiler_tracer.etf_read_direct
- kind: tagged_tests
  execute: true
  covers:
    - specled.compiler_tracer.merge_on_flush
    - specled.compiler_tracer.session_module_replacement
    - specled.compiler_tracer.seed_time_ghost_prune
- kind: tagged_tests
  execute: true
  covers:
    - specled.compiler_tracer.xref_in_process
- kind: source_file
  target: lib/specled_ex/compiler/tracer.ex
  execute: true
  covers:
    - specled.compiler_tracer.single_file_cap
```
