---
id: specled.decision.tracer_manifest_merge_on_flush
status: accepted
date: 2026-07-02
affects:
  - specled.compiler_tracer
  - specled.implementation_tier
  - specled.compiler_context
  - specled.mix_tasks
change_type: refines
---

# Tracer Manifest Merges On Flush; Read-Time Filtering Is The Authoritative Prune

## Context

`SpecLedEx.Compiler.Tracer` wrote `_build/<env>/.spec/xref_mfa.etf` by
serializing its session ETS edge table on every `:on_module` — replace
semantics. The ETS table only holds edges from modules compiled in the
current session, so any incremental compile replaced the full callee graph
with the recompiled subset (measured: 1145 caller MFAs / 79 modules / 8311
edges collapsed to 14 / 1 / 95 after a one-module recompile). Every
implementation-tier closure walk downstream then ran on a truncated graph:
spurious drift, missed drift, and — when hashes were committed from that
state — a corrupted baseline. Consumers with warm CI caches hit this as the
steady state (Atlas: 50–58 varying drift findings run-to-run; worked around
with `mix compile --force` at 2–4 min/run). A debug session established the
hash pipeline itself is deterministic given a stable manifest, so the
manifest write semantics are the whole bug.

Two adjacent defects surfaced in the same investigation: production never
constructed a `%SpecLedEx.Compiler.Context{}` (mix tasks pass no
`:context`), so the implementation tier's world had a nil compile manifest —
`in_project?` collapsed to binding modules and shared-helper inlining was
inert; and `Context.load/1`'s default manifest path resolved under `ebin/`,
loading zero modules even when a context was constructed with defaults.

## Decision

1. **Merge-on-flush.** The tracer tracks modules compiled this session (from
   `:on_module`, never from edge callers, so a recompiled module with zero
   remote calls still replaces its stale entries) in a second named public
   ETS meta table. On flush it computes: pre-session manifest (read once per
   session, cached as a single `{:merge_base, map}` ETS object) minus entries
   whose caller module was compiled this session, union the session's edges,
   written atomically (temp file + rename) with sorted, deduplicated callee
   lists. The pre-existing stale-last-write race between parallel flushes is
   accepted unchanged: every write is internally consistent and the next
   compile converges; no file locking.

2. **Prune split.** Ghost entries (deleted/renamed modules) are pruned in two
   places with different guarantees: at merge-base seed time against the
   on-disk compile manifest (lags one compile, since that manifest is stale
   during a compile — bounds file growth), and authoritatively at read time:
   `Implementation.build_world/3` drops tracer edges whose caller module is
   outside the in-project set whenever the context carries a non-empty
   compile manifest. A nil or empty manifest never filters (a cold build must
   not erase the graph).

3. **Production context.** `mix spec.check` constructs the compile context
   via `Context.from_mix_project/1` — the only Context constructor that
   consults Mix globals; `load/1` stays Mix-free — when its root is the
   current working directory, and passes none otherwise. `Context.load/1`'s
   default manifest path becomes the sibling `.mix/compile.elixir` of the
   app's `ebin` directory.

## Consequences

- Incremental compiles preserve the full callee graph: the effective edge
  graph after an incremental compile equals the graph after `--force`.
  Consumers can drop `mix compile --force` workarounds.
- Implementation-tier hashes become stable across warm-build runs; two
  consecutive no-change runs produce identical hashes and findings.
- Wiring the compile manifest into production grows closures (walks now
  traverse the true in-project set and inline shared helpers), so committed
  implementation hashes change: consumers must re-seed the `implementation`
  section of `.spec/realization_hashes.json` once. specled_ex's own committed
  baseline is api_boundary-only and unaffected.
- The manifest file may briefly carry ghost entries for up to one compile
  (seed-time prune lag); correctness does not depend on the file being
  ghost-free because read-time filtering is authoritative.
- Same-VM repeated compiles (iex loops) still accumulate stale edges in the
  VM-lifetime ETS table — pre-existing, explicitly out of scope.
