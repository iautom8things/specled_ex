---
id: specled.decision.per_test_sync_boundary
status: accepted
date: 2026-07-24
affects:
  - specled.coverage_capture
change_type: supersedes
replaces:
  - specled.decision.aggregate_first_spec_coverage
---

# Per-Test Attribution Via Synchronous Boundary Hook: Exact Up To Escaped Processes

## Context

`specled.decision.aggregate_first_spec_coverage` correctly made aggregate
ingest the default coverage path and honestly disclosed that the opt-in
`--per-test` lane was race-bounded (`specled_-cpw`): `ExUnit.Runner`
notifies formatters of `test_finished` via `GenServer.cast` and does not
wait for the formatter to process that cast before spawning the next test,
so a lazy formatter-side snapshot for test N can capture test N+1's already
begun counter progress. That ADR left the fix out of scope: a synchronous
per-test hook running inside each test's own process, since `on_exit` is
the one place the Runner *does* wait before advancing.

Stage 1 of epic `specled_-pzd` landed the boundary engine
(`SpecLedEx.Coverage.Boundary`, `setup {SpecLedEx.Coverage,
:per_test_boundary}`, `use SpecLedEx.Case`) and a transitional
boundary-row preference in the formatter while lazy capture still ran for
unhooked tests. Stage 2 completes the architectural flip: the formatter
demotes to auditor, unhooked modules degrade honestly, and every claim
surface upgrades from "observed/approximate, never exact" to **"exact up
to escaped processes"** for hooked windows.

## Decision

### Boundary hook is the measurement engine

Exclusive per-test attribution is produced only by the synchronous
boundary hook:

- Head snapshot at test setup (`Boundary.head/1`).
- Tail snapshot in the test's `on_exit` callback (`Boundary.tail/3`), which
  `ExUnit.Runner` awaits via `exec_on_exit/3` before spawning the next
  test.
- Diff via `Snapshot.diff/2` over the `[head, tail]` window; row inserted
  into a public anonymous ETS table armed by
  `mix spec.cover.test --per-test` through the existing
  `:specled_ex, :spec_cover_run` keyword seam (`boundary_table: tid`).

Public adopter API: `setup {SpecLedEx.Coverage, :per_test_boundary}` (or
`use SpecLedEx.Case` for bare `ExUnit.Case` modules). The hook no-ops when
unarmed, so the wiring is safe under plain `mix test`.

### Formatter is the suite-lifecycle auditor, not the measurer

`SpecLedEx.Coverage.Formatter` retains suite lifecycle ownership
(`suite_started` baseline, inventory on `test_finished`, audit + artifact
write on `suite_finished`) but takes **no per-test snapshots**. The
lazy-capture fallback is deleted. On `suite_finished`:

1. One final whole-scope snapshot; run-total =
   `Snapshot.diff(baseline, final)`.
2. Attributed = union of boundary rows → per-test `:payload`.
3. Unattributed remainder (line-level set subtraction) →
   `meta.unattributed` as `[{file, sorted_lines}]` and contributes to
   `envelope.files`.
4. Inventory vs boundary keys, grouped by module →
   `meta.unhooked_modules`; envelope `degraded: true` when any test is
   unhooked (in addition to async / externally-harvested diagnostics).
5. One per-module (never per-test) stderr remediation notice naming the
   literal setup line.

A zero-hooked run with a non-empty remainder still writes the degraded
envelope; only a genuinely empty run refuses.

### Claim: exact up to escaped processes

For hooked tests under `--per-test`, per-test `lines_hit` are **exact up
to escaped processes**: a process a test spawns that outlives its tail
snapshot can still increment shared `:cover`/native counters after the
window closes, landing in a later window or the unattributed remainder.
No runtime detection of escaped processes is promised. Unhooked modules
are never claimed exact — they degrade as above.

This supersedes the "race-bounded, never exact" section of
`specled.decision.aggregate_first_spec_coverage` for the `--per-test`
lane. Aggregate-first default, v2 envelope shape, read-only
never-`:cover.reset` invariant, OTP posture, legacy rejection, task name,
and consumer scope from that ADR remain authoritative unchanged.

### Lane design amendment

`specled.decision.serialized_per_test_coverage`'s opt-in lane design is
amended only insofar as: (a) the formatter is auditor rather than
per-test snapshotter, and (b) exclusive attribution requires the boundary
hook wiring. Serialization (`ExUnit.configure(async: false)`), arming
seam, anonymous ETS, and `snapshot_fn`/`modules_fn` DI seams remain.

## Consequences

- **Positive:** hooked tests get deterministic exclusive attribution
  (seeded exclusivity integration test; not statistical). The
  ExUnit cast-timing race (`specled_-cpw`) is closed for hooked windows.
- **Positive:** unhooked modules never fail a run — degrade + notice
  teaches the wiring, so adopters can adopt the hook incrementally.
- **Positive:** claim surfaces can honestly say "exact up to escaped
  processes" instead of over-disclosing a race that no longer applies to
  hooked windows.
- **Negative:** exclusive per-test attribution now costs one setup line
  per case template (or `use SpecLedEx.Case`). Zero-wiring remains true
  only for the default aggregate lane.
- **Negative:** escaped-process leakage is a disclosed bound, not a
  detected runtime condition.
- **Negative (deferred):** review/triangulation labels and adoption docs
  Phase 4a/4b still need their own stages to consume `meta` and teach
  the wiring cost (`specled_-pzd.3`, `specled_-pzd.4`).

## Related

- `specled.decision.aggregate_first_spec_coverage` — partially superseded
  (race-bound claim only); aggregate-first default and the rest remain.
- `specled.decision.serialized_per_test_coverage` — lane design amended
  as above; original Decision + 155.4/155.5 amendments still govern
  serialization, arming, and the snapshot engine.
- `specled.decision.adr_append_only` — this supersession is recorded by a
  new ADR plus an append-only cross-reference amendment on the prior ADR.
