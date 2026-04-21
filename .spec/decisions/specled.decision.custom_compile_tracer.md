---
id: specled.decision.custom_compile_tracer
status: accepted
date: 2026-04-21
affects:
  - specled.compiler_tracer
  - specled.implementation_tier
  - specled.use_tier
---

# Use A Custom `Code.Tracer` Side-Manifest For MFA Edges, Not Post-Hoc Xref JSON

## Context

The architecture originally planned to obtain MFA-level call edges by running
`mix xref graph --format json`. Red-team 04a#c1 verified against Elixir 1.18.1
that no such format exists; the supported formats are `pretty|plain|stats|
cycles|dot`. Building a parallel call-graph analyzer would also violate the
project's reuse-over-reinvent rule stated in `00-global-contracts.md`: do not
rebuild what the compiler already provides.

Elixir's supported seam for observing call edges during compilation is the
`Code.Tracer` behaviour. Tracers receive `remote_function`,
`imported_function`, `imported_macro`, and `:on_module` events in-band with
compilation, giving us the calling MFA and callee MFA deterministically. The
coarse `mix xref graph --format dot --output -` output still serves the
project-level file/module edge-kind classification (compile / exports /
runtime), which we invoke in-process via `Mix.Task.run/2` — no subprocess.

## Decision

SpecLedEx ships `SpecLedEx.Compiler.Tracer`, a `Code.Tracer` registered in
`mix.exs` via `elixirc_options: [tracers: [SpecLedEx.Compiler.Tracer]]`, for
this project and for the `test/fixtures/sample_project/` fixture. It writes
an ETF side-manifest to `_build/<env>/.spec/xref_mfa.etf` on the `:on_module`
event, keyed by calling module/function/arity. Tier orchestrators read this
file directly via `:erlang.binary_to_term/1`.

For file/module edge classification, `SpecLedEx.Compiler.Xref.load/1` calls
`Mix.Task.run("xref", ["graph", "--format", "dot", "--output", "-"])`
in-process and parses the DOT output. Neither tracer nor xref shells out to a
subprocess.

## Consequences

- Positive: MFA edges are available in-band with compile; no format drift risk
  from xref JSON that does not exist.
- Positive: reuse rule is satisfied — we do not build a parallel call-graph
  analyzer.
- Negative: the tracer runs during every compile, adding measurable overhead.
  Users who do not care about `implementation`/`use` tiers can opt out by
  removing the tracer from `elixirc_options`; in that case the side-manifest
  is absent and those tiers emit `detector_unavailable`.
- Negative: DOT parsing is a small codebase footprint we own. Format drift at
  Elixir minor bumps surfaces as `Xref.load/1` test failure, not silent
  misread.
