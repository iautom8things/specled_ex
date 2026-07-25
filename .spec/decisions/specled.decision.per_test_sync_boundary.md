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

# Per-Test Attribution Via Chained Synchronous Boundary Windows

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

The first implementation retained a whole-scope head snapshot inside every
test's `on_exit` closure. ExUnit's on-exit handler copies that environment,
making the retention cost scale with the entire module/line snapshot. Chaining
removes that closure copy, but it adds an ETS write copy of each whole tail
snapshot and an ETS read copy of the whole snapshot per hooked test when the
next tail diffs against it; the final tail also remains retained in the table
for the rest of the run. Chaining also changes the measured interval and
therefore requires a narrower attribution claim.

## Decision

### Boundary hook is the measurement engine

Exclusive per-test attribution is produced only by the synchronous
boundary hook:

- One initial head snapshot (`Boundary.head/1`).
- Tail snapshot in each test's `on_exit` callback (`Boundary.tail/2`), which
  `ExUnit.Runner` awaits via `exec_on_exit/3` before advancing.
- Each tail is retained in the boundary ETS table as the next test's head:
  `tail(N) == head(N+1)`. The on-exit closure therefore retains only the
  `{module, name}` test key, never a whole-scope snapshot.
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

### Claim: exact within a disclosed chained window

For hooked tests under `--per-test`, per-test `lines_hit` are exact within
the chained `[head, tail]` measurement window. For the first hooked test,
the head is taken in its setup. For every later hooked test, the head is the
prior hooked test's tail, so the window also contains everything before the
current test's setup: serialized `ExUnit.Runner` / `setup_all` activity and
any intervening unhooked tests. The implementation does not prove that
interval empty and therefore does not claim test-body-only attribution for
it.

A process a test spawns that outlives its tail snapshot remains the second
bound: it can increment shared `:cover`/native counters after the window
closes, landing in a later window or the unattributed remainder. No runtime
detection of either between-test activity or escaped processes is promised.
Unhooked modules are never claimed exact — they degrade as above.

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

- **Positive:** hooked tests get deterministic, disjoint chained windows
  (seeded exclusivity integration test; not statistical). The
  ExUnit cast-timing race (`specled_-cpw`) is closed for hooked windows.
- **Positive:** the boundary costs one initial whole-scope snapshot plus one
  whole-scope tail snapshot per hooked test, plus the ETS write/read copies
  named in Context; the on-exit closure retains only the test key instead of
  a whole snapshot.
- **Positive:** unhooked modules never fail a run — degrade + notice
  teaches the wiring, so adopters can adopt the hook incrementally.
- **Positive:** claim surfaces can honestly say "exact within the disclosed
  chained window" instead of over-disclosing a formatter race or hiding the
  between-test interval.
- **Negative:** exclusive per-test attribution now costs one setup line
  per case template (or `use SpecLedEx.Case`). Zero-wiring remains true
  only for the default aggregate lane.
- **Negative:** between-test runner / `setup_all` activity, and any unhooked
  tests scheduled between hooked tests, are attributed to the following
  hooked test's chained window.
- **Negative:** escaped-process leakage is a disclosed bound, not a detected
  runtime condition.
- **Negative:** the final hooked test's tail snapshot remains in the boundary
  ETS table until suite end; any process that raises coverage after that tail
  lands in the unattributed remainder, not in a later per-test window.
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
