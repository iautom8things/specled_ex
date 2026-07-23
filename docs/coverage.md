# Coverage

<!-- covers: specled.coverage_capture -->

How `mix spec.cover.test` captures the coverage side of the triangle, what
the two headline numbers actually mean, the opt-in per-test lane and its
honest limits, and the full catalogue of ways a run can refuse.

## One-command entry

```bash
mix spec.cover.test
```

That is the whole setup. Never add `SpecLedEx.Coverage.Formatter` to
`test/test_helper.exs` or anywhere else — it is inert unless `mix
spec.cover.test` itself arms it (see "Disarmed by default" below). By
default the task runs plain `mix test --cover --export-coverage specled`
— no custom formatter, no `ExUnit.configure(async: false)`, nothing that
changes how your suite executes — and then, guarded by the exported
`.coverdata` file's existence, ingests it into a versioned envelope at
`.spec/_coverage/per_test.coverdata`:

```
Cover compiling modules ...
Running ExUnit with seed: 971177, max_cases: 24

..
Finished in 0.01 seconds (0.00s async, 0.01s sync)
2 tests, 0 failures

Exporting cover results ...
mix spec.cover.test: ingested 1 files, 3 mfas into .spec/_coverage/per_test.coverdata
```

This default mode is async-safe and O(codebase) — the cost of `mix test
--cover` itself plus one bounded ingest pass, not one pass per test. It
answers one question: *was this MFA executed by any test in the suite?*
It does not and cannot say *which* test. `mix spec.check` never reads this
artifact and never gates on it; `mix spec.triangle` and `mix spec.review`'s
Coverage tab are the two consumers (see
`specled.decision.aggregate_first_spec_coverage`).

The task's exit code passes through the wrapped `mix test` status: a red
suite still exits non-zero even though its real, non-placeholder coverage
is ingested. After a suite that ran to completion, an ingestion refusal
(see the catalogue below) additionally forces a non-zero exit.

## Coexisting with coveralls / existing CI coverage

If your CI already exports a `.coverdata` file for coveralls or another
tool — `mix test --cover --export-coverage <name>` — you do not need a
second, redundant coverage run. `mix spec.cover.ingest` is the escape
hatch: it ingests any exported `.coverdata` into the same versioned
envelope for free.

```bash
mix test --cover --export-coverage ci_run   # your existing coveralls step
mix spec.cover.ingest cover/ci_run.coverdata
```

```
Wrote .spec/_coverage/per_test.coverdata (1 files, 3 mfas)
```

`--output PATH` overrides the destination (defaults to
`SpecLedEx.Coverage.Store.default_path/0`, the same
`.spec/_coverage/per_test.coverdata` the default `spec.cover.test` path
writes). Running with no arguments prints usage and exits non-zero:

```
$ mix spec.cover.ingest
** (Mix) usage: mix spec.cover.ingest <path/to/file.coverdata> [--output PATH]
```

## What the numbers mean

Two distinct metrics come out of a coverage artifact, and they are not
interchangeable:

- **Coverage percent (aggregate).** "N/M requirements' realization-closure
  MFAs covered by ANY test" — computed by
  `SpecLedEx.CoverageTriangulation.aggregate_requirement_reach/2` as the
  intersection of a requirement's closure MFAs with the envelope's `:mfas`
  list. This proves a closure MFA ran during the suite; it does not and
  cannot attribute that execution to any specific test. This is what a
  plain (no `--per-test`) artifact supports.
- **Self-verified (composite, not a percent).** A boolean per requirement,
  computed by `SpecLedEx.Review.CoverageClosure.build_v2/2`:
  `closure_coverage_pct > 0` **and** at least one `@tag spec:`-tagged test
  reached `"executed"` evidence strength. Under aggregate-only coverage a
  tagged test can only reach `"linked"` (tag exists, some execution
  occurred somewhere) or `"claimed"` (tag exists, zero confirmed
  execution) — `"executed"`, and therefore `self_verified? == true`, is
  only reachable when a `--per-test` artifact backs the specific tagged
  test. There is never a synthesized "N% of tests confirm this
  requirement" figure — `self_verified?` is a yes/no composite, not a
  percentage.

## `--per-test`: opt-in, race-bounded, never "exact"

```bash
mix spec.cover.test --per-test
mix spec.cover.test --per-test --allow-async
```

This is the old serialized-capture design, now opt-in. It forces
`Application.put_env(:ex_unit, :async, false)` and
`ExUnit.configure(async: false)` before any test module loads, then arms
`SpecLedEx.Coverage.Formatter` to snapshot coverage per test:

```
Cover compiling modules ...
Running ExUnit with seed: 586071, max_cases: 24

..
Finished in 0.01 seconds (0.00s async, 0.01s sync)
2 tests, 0 failures

Generating cover results ...

Percentage | Module
-----------|--------------------------
   100.00% | Covered
-----------|--------------------------
   100.00% | Total
```

**Async contamination is a hard failure by default.** A test file that
declares `async: true` genuinely runs concurrently regardless of the
forced global default (an explicit per-module setting overrides it), which
corrupts serialized per-test attribution. Without `--allow-async` the task
refuses before running the suite, naming every contaminated file:

```
** (Mix) [spec.cover.test --per-test] the following test files set `async: true`, which corrupts serialized per-test :cover attribution:
  - test/async_true_test.exs
Pass --allow-async to run anyway with a degraded (unreliable for those tests) capture.
```

`--allow-async` degrades instead of failing — the suite still runs and the
task still exits 0, but stderr carries a warning and the written envelope
is marked `degraded: true`:

```
[spec.cover.test --per-test] WARNING: degraded run -- the following test files set `async: true` during a serialized per-test coverage run; their per-test attribution may be unreliable:
  - test/async_true_test.exs
```

**Even on a clean, non-degraded run, per-test attribution is
observed/approximate — never exact (`specled_-cpw`).** `ExUnit.Runner`
notifies formatters of `test_finished` via `GenServer.cast` and does not
wait for the formatter to process it before starting the next test. Because
this formatter's snapshot for test N is taken lazily inside its own
`test_finished` handler, test N+1's freshly-spawned process can begin
executing — and incrementing the same shared `:cover`/native counters —
before the formatter reads them for test N. Measured empirically at
roughly 1-in-3 exclusive-attribution failures on a trivial two-test
fixture. The `degraded` flag catches async-tagged tests and
externally-harvested counters; it cannot catch this race, since the race
can occur on an otherwise well-behaved serialized run. Any claim about
`--per-test` data in your own docs or code comments should say "observed"
or "approximate," never "exact."

**Cost model.** Arming `--per-test` never changes the coverage totals
`mix test --cover` itself exports (a tripwire test diffs decoded
`.coverdata` content with and without it armed and requires them equal).
The cost is the forced serialized run itself, plus one coverage snapshot
per test — proportional to test count, unlike the aggregate default.

**Scoping knobs.** `SpecLedEx.Coverage.Formatter` accepts `snapshot_fn`
(default dispatches to `SpecLedEx.Coverage.Snapshot.take/2`) and
`modules_fn` (default `SpecLedEx.Coverage.cover_modules_safe/0`) as
dependency-injection seams; these are for test authoring inside this
package, not adopter-facing configuration.

## OTP posture

`SpecLedEx.Coverage.Snapshot.runtime_mode/0` dispatches on
`:code.coverage_support/0`: native (`:code.get_coverage/2`) when true,
classic (`:cover.analyse/3`) otherwise. specled recommends OTP >= 27.2 for
the native path but never hard-gates on it — an older OTP release falls
back to the classic engine automatically, with no flag to set.

## Prerequisites: the compile tracer manifest

A coverage percentage is only as complete as the requirement's realization
closure. For subjects that declare `realized_by.implementation:`, the
closure walk needs the compile tracer's manifest (populated automatically
by `mix compile` when the tracer is registered). Without it, `mix
spec.triangle` still runs but skips the closure walk and says so:

```
note: tracer manifest missing; closure walk skipped
```

Run `mix compile` (not `--no-compile`) before `mix spec.triangle` or `mix
spec.review` if a subject's `implementation` tier closure looks
incomplete.

## Artifact hygiene

Two directories should be gitignored — this repo's own `.gitignore` does
both:

```
# If you run "mix test --cover", coverage assets end up here.
/cover/

# Generated by `mix spec.cover.test` for per-test coverage triangulation.
/.spec/_coverage/
```

**`generated_at` staleness.** The envelope's `generated_at` timestamp is
what lets a reviewer avoid mistaking coverage computed against an older
checkout for coverage of the code under review. `mix spec.review` flags an
artifact as possibly stale once it is more than 24 hours old
(`SpecLedEx.Review.Html.render_coverage_generated_at/1`):

> Coverage captured 2026-07-22T10:00:00Z (1d ago). — possibly stale;
> re-run `mix spec.cover.test` to refresh.

There is no automatic re-run trigger; re-running `mix spec.cover.test`
before `mix spec.review`/`mix spec.triangle` (for example as a CI step,
see [`README.md`](../README.md)) keeps the artifact current.

## Refusal-reason catalogue

Every way a coverage command can refuse, with the real message and the fix.

| Situation | Command | What you see | Fix |
|---|---|---|---|
| Suite exercises zero application modules | `mix spec.cover.test` | `** (Mix) mix spec.cover.test: cover/specled.coverdata carries no cover-compiled modules (empty coverage)` — non-zero exit; `Store.read_status/1` on the artifact path reports `{:refused, ...}` | The suite needs to actually exercise `lib/` code under `--cover`; a suite of pure unit tests against stubs with no app-module calls will trip this. |
| Foreign `.coverdata` carries zero cover-compiled modules | `mix spec.cover.ingest` | `** (Mix) cover/empty_ci.coverdata carries no cover-compiled modules (empty coverage)` — non-zero exit; same refused sidecar written at the output path | Re-export from a run that actually touches `lib/` code. |
| `--per-test` run has an `async: true` test file, no `--allow-async` | `mix spec.cover.test --per-test` | `** (Mix) [spec.cover.test --per-test] the following test files set \`async: true\`, which corrupts serialized per-test :cover attribution: ...` — non-zero exit, no artifact written | Remove `async: true` from the named file(s), or pass `--allow-async` to degrade instead of failing. |
| Artifact on disk is pre-v2 (bare record list) | any reader (`Store.read_v2/1`) | `{:error, :legacy_artifact, "Legacy per-test coverage artifact detected (pre-v2 format). specled does not auto-migrate or delete it -- re-run \`mix spec.cover.test\` to regenerate a v2 artifact."}` | Re-run `mix spec.cover.test`. specled never auto-migrates or deletes the stale file (maintainer decision 5). |
| Artifact on disk does not decode as any known coverage shape | any reader (`Store.read_v2/1`) | `{:error, :invalid_artifact}` | Delete the file and re-run `mix spec.cover.test`; something outside specled wrote or corrupted it. |
| Formatter registered in `:formatters` but not armed by the task | plain `mix test` / `ExUnit.start(formatters: [..., SpecLedEx.Coverage.Formatter])` | `[SpecLedEx.Coverage.Formatter] disabled: per-test coverage capture requires \`mix spec.cover.test --per-test\` (it arms via Application.put_env(:specled_ex, :spec_cover_run, true)). Wiring this formatter directly into ExUnit.start/1 without that task is a no-op.` — one stderr notice, suite proceeds normally, no coverage artifact written | Delete the wiring. Never add the formatter to `test_helper.exs`; run `mix spec.cover.test` (or `--per-test`) instead. |
| `--per-test` flush produces zero records | `mix spec.cover.test --per-test` | `[SpecLedEx.Coverage.Formatter] no per-test coverage hits were captured this run; no artifact was written.` | The suite ran but touched no scoped module from any test's perspective; check `modules_fn`/scope if customized. |
| A snapshot read a lower count than the prior boundary | `mix spec.cover.test --per-test` | `[SpecLedEx.Coverage.Formatter] N counters-externally-harvested diagnostic(s): a snapshot read a lower count than the previous boundary snapshot for the same line, meaning something other than this formatter drained the shared coverage counters mid-run. The artifact is marked degraded rather than treating the decrease as a real (negative) delta.` — envelope written with `degraded: true` | Something else in the same BEAM called `:cover.reset/0` / `:code.reset_coverage/1` (this module never does). Find and remove that call. |

All of the above (except the diagnostic-notice row, which needs a
deliberately corrupted run to trigger) were reproduced by running the real
commands against a scratch fixture while writing this page.
