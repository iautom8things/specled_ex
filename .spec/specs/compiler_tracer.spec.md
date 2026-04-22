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

```spec-meta
id: specled.compiler_tracer
kind: module
status: draft
summary: SpecLedEx.Compiler.Tracer emits `{mod, fun, arity} => [callees]` ETF to `_build/<env>/.spec/xref_mfa.etf` on `:on_module`; Compiler.Xref runs `Mix.Task.run("xref", ["graph","--format","dot","--output","-"])` in-process and parses DOT.
surface:
  - lib/specled_ex/compiler/tracer.ex
  - lib/specled_ex/compiler/xref.ex
  - test/specled_ex/compiler/tracer_test.exs
  - test/specled_ex/compiler/xref_test.exs
  - mix.exs
  - test/fixtures/sample_project/mix.exs
decisions:
  - specled.decision.custom_compile_tracer
```

## Requirements

```spec-requirements
- id: specled.compiler_tracer.captures_remote_calls
  statement: >-
    SpecLedEx.Compiler.Tracer shall implement `trace/2` for the
    `remote_function` and `imported_function` events, accumulating
    `{caller_mfa, callee_mfa}` edges keyed on the calling module/fun/arity.
    On the `:on_module` event, it shall serialize the per-module entries
    to ETF at `_build/<env>/.spec/xref_mfa.etf`.
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
    `lib/specled_ex/compiler/tracer.ex`. If it grows past 300 LOC,
    helpers shall factor into `lib/specled_ex/compiler/tracer/` but the
    public surface (behaviour callbacks) shall stay on the top-level
    module.
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

```spec-scenarios
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

```spec-verification
- kind: command
  target: mix test test/specled_ex/compiler/tracer_test.exs --include integration
  execute: true
  covers:
    - specled.compiler_tracer.captures_remote_calls
    - specled.compiler_tracer.registered_in_mix_exs
    - specled.compiler_tracer.etf_read_direct
- kind: command
  target: mix test test/specled_ex/compiler/xref_test.exs --include integration
  execute: true
  covers:
    - specled.compiler_tracer.xref_in_process
- kind: source_file
  target: lib/specled_ex/compiler/tracer.ex
  execute: true
  covers:
    - specled.compiler_tracer.single_file_cap
```
