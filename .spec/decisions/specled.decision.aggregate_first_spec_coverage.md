---
id: specled.decision.aggregate_first_spec_coverage
status: accepted
date: 2026-07-23
affects:
  - specled.coverage_capture
  - specled.triangulation
  - specled.spec_review
change_type: supersedes
replaces:
  - specled.decision.serialized_per_test_coverage
---

# Aggregate-First Spec Coverage: Aggregate Ingest Is The Default, Per-Test Attribution Is Opt-In And Race-Bounded

## Context

`specled_-47j` found that the coverage capture default shipped under
`specled.decision.serialized_per_test_coverage` was actively harmful on the
path most adopters actually took:

1. **The default snapshot fabricated data.** `Coverage.init/2` defaulted
   `snapshot_fn` to the arity-1 `:cover.analyse/1`, which is function-level
   (`{{m,f,a}, {cov, not_cov}}`), not line-level. The formatter's decoder
   fallback laundered every such entry into a `{file, 0}` record, so a real
   `.spec/_coverage/per_test.coverdata` on disk carried zero per-test line
   discrimination while looking well-formed (381,142 records, all identical
   file lists, `lines_hit == [0]` throughout, observed against a real
   downstream suite).
2. **The default cost was O(tests × cover-compiled modules)**, in both time
   and memory — one full-project `:cover.analyse` per `test_finished`, every
   snapshot retained in ETS until `suite_finished`. Measured at ~17 minutes
   added silently to a 1,480-test CI run and ~6.5 GB peak local RSS at
   1,273 tests. Because `test_finished` casts drain *after* the CLI summary
   prints, this presented as an unexplained CI hang, not a slow test run.
3. **Nothing detected off-spec adoption.** `docs/adoption.md` itself
   instructed adopters to wire the formatter directly into
   `test_helper.exs` — exactly the unserialized, unsupported configuration
   the original ADR declared out of bounds — and the formatter ran
   silently in that configuration rather than refusing.

A 33-agent root-cause validation (9/9 consolidated claims confirmed) traced
this to: the function-level default entering the pipeline at all (RC1); the
MFA-fallback fabrication clause (RC2); the absence of test-to-test
diffing, which any naive fix by adding `:cover.reset/0` would have made
worse by corrupting the wrapped `mix test --cover` tally (RC3, latent); the
per-test O(tests × functions) time/memory cost (RC4/RC5); and the
post-summary hang being an unbacked `GenServer.cast` backlog (RC6). The
same investigation found zero production callers of per-test line
identities — the coarsest granularity anything downstream actually
consumed was per-test × file boolean reachability — and that
`mix spec.check` had never run triangulation despite documentation implying
it did.

Five maintainer decisions (2026-07-23) resolved the remediation direction
for the epic (`specled_-155`) that this ADR closes out:

1. Triangulation consumers are `mix spec.triangle` and `mix spec.review`
   only. `mix spec.check` does not run triangulation and never will — it
   stays fast. No gate-wiring follow-up.
2. Keep the task name `mix spec.cover.test`; carry the behavior change via
   loud 0.4.0 release notes instead of a rename.
3. The rebuilt `--per-test` lane ships in the same release as the
   aggregate-first default, not deferred.
4. OTP posture: recommend OTP >= 27.2 for the native per-test path: never
   hard-gate on it.
5. Legacy (pre-v2) artifacts are rejected with a message naming the re-run
   command; never auto-migrated or deleted.

Separately, `specled_-155.5`'s per-test engine rebuild surfaced a
pre-existing defect this ADR must disclose honestly rather than paper
over: `specled_-cpw`, an ExUnit event-timing race that bounds per-test
attribution even when nothing else is wrong with the run (see "Per-test
attribution is race-bounded" below).

## Decision

### Aggregate-first default

By default, `mix spec.cover.test` runs plain
`mix test --cover --export-coverage specled` — no custom formatter
registered, no `ExUnit.configure(async: false)`, no per-test bookkeeping —
and then ingests the exported `.coverdata` via
`SpecLedEx.Coverage.Aggregate.ingest/2` into a versioned v2 envelope
(`SpecLedEx.Coverage.Store.build_envelope/1`, `mode: :aggregate`). This is
async-safe and O(codebase), not O(tests × modules): the cost of running
`mix test --cover` itself, plus one bounded ingest pass, regardless of
suite size. `mix spec.cover.ingest <path.coverdata>` is the CI/coveralls
escape hatch for a `.coverdata` produced by any other invocation.

### Headline metric: percentage of realization-closure MFAs covered by ANY test

The metric spec coverage reports by default is not "which test executed
this line" — it is **the percentage of a requirement's realization-closure
MFAs that were executed by any test in the suite**, computed by
`SpecLedEx.CoverageTriangulation.aggregate_requirement_reach/2` as the
intersection of a requirement's closure MFAs with the envelope's `:mfas`
list, partitioned by each MFA's `:covered` boolean. This is honest about
what aggregate `:cover` data can and cannot say: it proves a closure MFA
ran during the suite: it does not and cannot attribute that execution to
any specific test.

### Self-verified composite verdict, never a fabricated per-test percent

`SpecLedEx.Review.CoverageClosure.build_v2/2` derives `self_verified?` per
requirement as a boolean composite — `closure_coverage_pct` is a positive
number **and** at least one `@tag spec:`-tagged test reached `"executed"`
evidence strength — never a synthesized "N% of tests confirm this
requirement" figure. Under `:ok_aggregate` a tagged test can only reach
`"linked"` (tag exists, and the envelope confirms some execution
occurred) or `"claimed"` (tag exists, zero confirmed execution); `"executed"`
— and therefore `self_verified? == true` — is only reachable under
`:ok_per_test`, where a specific tagged test's own per-test record reached
the closure. Aggregate mode's `"linked"` ceiling is deliberate: it cannot
manufacture a specific-test claim from data that has no per-test shape.

### Versioned v2 envelope

The per-test artifact schema described by the original ADR
("no in-band version field; downstream consumers bump their
`hasher_version`") is superseded for the production write path.
`SpecLedEx.Coverage.Store`'s v2 envelope
(`version: 2, mode:, generated_at:, source:, files:, mfas:, payload:,
degraded:`) carries an in-band version field, targets the same on-disk
path (`.spec/_coverage/per_test.coverdata`), and is what
`SpecLedEx.Coverage.Aggregate.ingest/2` and
`SpecLedEx.Coverage.Formatter` actually write. The v1 bare record list
(`Store.write/2` / `Store.read/1` / `Store.build_records/1`) is not
removed — it remains the schema of a `:per_test` envelope's `:payload`
and a test-authoring helper — but it is no longer the shape written to
disk by either production path.

### Read-only, never-`:cover.reset` invariant

Neither the aggregate ingest path nor the per-test snapshot-diff engine
ever calls `:cover.reset/0` or `:code.reset_coverage/1`. This was verified
empirically in-worktree on OTP 27.2 (erts-15.2): `:code.get_coverage/2` is
a pure, idempotent read of a module's native counters, while
`:cover.analyse/3` drains the same counters as a side effect even though
its own return value stays correctly cumulative. `SpecLedEx.Coverage.Snapshot.diff/2`
treats a strictly-decreased count as a `"counters externally harvested"`
diagnostic — never a negative or fabricated hit — and the run's envelope
is marked `degraded: true` when this occurs. A child-BEAM tripwire test
diffs decoded `.coverdata` content with and without `--per-test` armed and
requires them equal, proving this formatter's own reads never perturb
`mix test --cover`'s final report.

### OTP posture: recommend, never hard-gate

`SpecLedEx.Coverage.Snapshot.runtime_mode/0` dispatches on
`:code.coverage_support/0` — native when true, classic otherwise — and
never hard-gates on a specific OTP release. `native_snapshot/1` wraps each
module read in its own try/catch, treating an `ArgumentError` (module not
loaded or never cover-compiled) as `[]` for that module rather than
aborting the snapshot. specled recommends OTP >= 27.2 for the native path
in documentation; it does not refuse to run on older releases, per
maintainer decision 4.

### Legacy artifacts are rejected, never migrated

`SpecLedEx.Coverage.Store.read_v2/1` returns
`{:error, :legacy_artifact, message}` for an artifact that decodes as a
pre-v2 bare list, naming `mix spec.cover.test` as the re-run command.
Consumers (`CoverageTriangulation.envelope_findings/3`,
`SpecLedEx.Review.CoverageClosure.build_v2/2`) surface this as its own
distinct degraded status, never collapsing it into `:invalid_artifact` or
`:no_coverage_artifact`, and specled never auto-migrates or deletes the
stale file, per maintainer decision 5.

### Task name unchanged

`mix spec.cover.test` keeps its name across this behavior change. The
default-mode change (aggregate ingest instead of forced serialization) is
carried by loud 0.4.0 release notes rather than a rename, per maintainer
decision 2.

### Consumers: `mix spec.triangle` and `mix spec.review` only

Coverage triangulation findings (`branch_guard_untested_realization`,
`branch_guard_untethered_test`, `branch_guard_underspecified_realization`,
and the envelope-path equivalents from
`CoverageTriangulation.envelope_findings/3`) are read-only diagnostics
consumed exclusively by `mix spec.triangle` and `mix spec.review`.
`mix spec.check` does not run triangulation, has never run it despite
prior documentation implying otherwise, and this ADR forecloses wiring it
into the gate: `mix spec.check` stays fast, per maintainer decision 1.

### Per-test attribution is race-bounded, not exact (specled_-cpw)

The rebuilt `--per-test` lane (native/classic snapshot-diff engine,
`SpecLedEx.Coverage.Snapshot`) ships in the same release as the
aggregate-first default, per maintainer decision 3. It remains opt-in and
still forces `ExUnit.configure(async: false)` for the run it captures, per
the original ADR's rationale (retained verbatim below).

It is not, however, exact. `ExUnit.Runner` notifies formatters of
`test_started`/`test_finished` via `GenServer.cast` and does not wait for
the formatter to process that cast before spawning the next test. Because
this formatter's snapshot for test N is taken lazily inside its own
`test_finished` handler, the next test's freshly-spawned process can begin
executing — and incrementing the same shared `:cover`/native counters —
before the formatter reads them for test N. Measured empirically at
roughly 1-in-3 exclusive-attribution failures on a trivial two-test
fixture (`specled_-cpw`); the race affects the native and classic engines
identically, since it is about event timing, not the read mechanism. The
`degraded` flag on a `:per_test` envelope catches async-tagged tests and
externally-harvested counters — it does not and cannot catch this race,
since the race can occur on an otherwise well-behaved serialized run.

Every claim surface that describes `--per-test`/`:ok_per_test` data —
`SpecLedEx.Coverage.Formatter`'s moduledoc, the `coverage_capture` and
`spec_review` requirement statements, and the review artifact's rendered
labels — must therefore describe per-test attribution as **observed** or
**approximate**, never **exact**, and reference `specled_-cpw` as the
disclosed bound. Closing the race fully likely requires a synchronous
per-test hook running inside each test's own process (e.g. a
`CaseTemplate`-based `setup`/`on_exit` pair, since `on_exit` is the one
thing `ExUnit.Runner` waits on before advancing) — a materially bigger
adoption/architecture change than a formatter patch, and out of scope for
this ADR.

### What is retained verbatim from the superseded ADR

The opt-in `--per-test` lane's design — forcing
`ExUnit.configure(async: false)` and
`Application.put_env(:ex_unit, :async, false)` before any test module
loads, keying per-test ETS state by `{module, name}` (or an
opt-in `test_pid` tag), the anonymous-ETS requirement so parallel
formatter instances in unit tests cannot collide, and the
`snapshot_fn`/`modules_fn` dependency-injection seams — is unchanged and
remains governed by `specled.decision.serialized_per_test_coverage`'s
original Decision section and its `specled_-155.4` (arming seam, no
fabrication) and `specled_-155.5` (native/classic snapshot-diff, read-only
invariant) amendments. This ADR does not restate that text; it supersedes
only the claim that serialization is the *default* posture for spec
coverage, not the technical design of the lane itself.

## Consequences

- **Positive:** the pathological default (`specled_-47j`'s fabricated
  records and O(tests × modules) cost) cannot recur — the default path no
  longer instantiates a custom formatter at all.
- **Positive:** the headline metric and the self-verified composite are
  each honest about their own evidentiary ceiling — aggregate mode never
  overclaims specific-test attribution, and per-test mode never overclaims
  exactness it cannot deliver.
- **Positive:** `mix spec.check` stays fast and its scope stays fixed;
  adopters who want triangulation diagnostics reach for
  `mix spec.triangle` / `mix spec.review` deliberately rather than
  inheriting them as a silent gate dependency.
- **Negative:** two coverage metrics now exist (aggregate closure-MFA
  coverage, and per-test attribution) with different evidentiary strength
  and different cost profiles; adopters must understand which one a given
  requirement's `self_verified?` is actually resting on.
- **Negative (known limitation, not closed by this ADR):** `--per-test`
  attribution is race-bounded per `specled_-cpw`. Adopters who need
  provably-exact per-test attribution do not yet have a supported path to
  it; the likely fix (a synchronous per-test `on_exit` hook) is tracked
  separately, not scheduled by this ADR.
- **Negative:** `:ok_per_test`'s per-requirement MFA coverage in the
  review artifact is still computed via a file-level proxy rather than the
  per-test engine's real per-line data — a wiring gap between this ADR's
  data layer and the review artifact's consumption of it, tracked as a
  follow-up rather than resolved here.

## Related

- `specled.decision.serialized_per_test_coverage` — partially superseded;
  its opt-in-lane design and both amendments remain authoritative (see
  "What is retained verbatim" above).
- `specled.decision.adr_append_only` — governs how this supersession is
  recorded (the old ADR's file is not deleted or rewritten; this new ADR
  and a brief cross-reference amendment there are the mechanism).
