# Per-Test Coverage Capture

Serialized per-test coverage collection via a custom ExUnit formatter and a
dedicated Mix task.

## Intent

`:cover` has no per-pid surface and races under `async: true`. By default
`mix spec.cover.test` no longer tries to force serialization at all: it runs
plain `mix test --cover --export-coverage specled` (no custom formatter, no
async configuration changes) and, guarded by the exported `.coverdata` file's
existence, ingests it via `SpecLedEx.Coverage.Aggregate.ingest/2` into a v2
`:aggregate` envelope (`specled.coverage_capture.default_aggregate_run`).
Forcing `ExUnit.configure(async: false)` globally never actually serialized a
module that itself declared `async: true` (an explicit per-module setting
overrides the global default) — an overclaim aggregate coverage does not need
in the first place, since `:cover`'s tally is process-global and unaffected by
concurrency for cumulative (non-per-test) attribution.

The old serialized flow survives as the opt-in `--per-test` flag
(`specled.coverage_capture.serialized_run`): it still forces
`ExUnit.configure(async: false)` and arms the custom formatter, which
snapshots coverage per-test into anonymous ETS (so multiple formatters can
coexist in tests), keyed by `{module, name}` by default — ExUnit does not
expose a test's runtime pid inside `test.tags`, so a `test_pid`-keyed row
exists only when the test itself opts in via `@tag test_pid: self()`.
Either key is unique per test under serialized execution, but key
uniqueness only rules out ETS-row collisions; it does not close the
underlying `ExUnit.Runner` event-timing race (`test_finished` is a
`GenServer.cast` the Runner does not wait on before starting the next
test), which can bleed a test's in-flight coverage into its neighbor's
snapshot — measured at roughly 1-in-3 exclusive-attribution failures on a
trivial fixture (`specled_-cpw`). Per-test attribution under `--per-test`
is therefore observed/approximate, never exact, even when the envelope is
not marked `degraded` (`degraded` flags only async-tagged tests and
externally-harvested counters, not this race — see
`specled.decision.aggregate_first_spec_coverage`). Under `--per-test`, a
test file that declares `async: true` genuinely does run concurrently
despite the global default and corrupts serialized attribution, so the
task exits non-zero naming it unless `--allow-async` degrades the run
instead. `mix test --cover` continues to work in its traditional
cumulative mode; only `mix spec.cover.test --per-test` produces the
per-test artifact at `.spec/_coverage/per_test.coverdata` (the default
aggregate mode's v2 envelope targets the same path).

The formatter is inert unless armed: registering it in `:formatters` is not
by itself enough to run it (ExUnit forwards its entire `:ex_unit` application
environment to every formatter it starts, so trusting a formatter's own init
argument would let unrelated config smuggle in). Only `mix spec.cover.test`
arms it, via a dedicated `:specled_ex` application-env seam. Once armed, the
formatter never fabricates a record for a snapshot entry it cannot attribute
to a real source line — unrecognized or function-level snapshot shapes are
counted and surfaced as decode errors instead.

```yaml spec-meta
id: specled.coverage_capture
kind: workflow
status: active
summary: `mix spec.cover.test` task + ExUnit formatter that captures per-test line coverage serialized; Store reads/writes `.spec/_coverage/per_test.coverdata`.
surface:
  - lib/specled_ex/coverage.ex
  - lib/specled_ex/coverage/formatter.ex
  - lib/specled_ex/coverage/snapshot.ex
  - lib/specled_ex/coverage/store.ex
  - lib/specled_ex/coverage/aggregate.ex
  - lib/specled_ex/coverage/mfa_key.ex
  - lib/mix/tasks/spec.cover.test.ex
  - lib/mix/tasks/spec.cover.ingest.ex
  - test/specled_ex/coverage/formatter_test.exs
  - test/specled_ex/coverage/snapshot_test.exs
  - test/specled_ex/coverage/store_test.exs
  - test/specled_ex/coverage/aggregate_test.exs
  - test/specled_ex/coverage/mfa_key_test.exs
  - test/mix/tasks/spec_cover_test_test.exs
  - test_support/specled_ex_integration_case.ex
realized_by:
  api_boundary:
    - "SpecLedEx.Coverage.init/2"
    - "SpecLedEx.Coverage.install/1"
    - "SpecLedEx.Coverage.default_artifact_path/0"
    - "SpecLedEx.Coverage.Formatter"
    - "SpecLedEx.Coverage.Snapshot.runtime_mode/0"
    - "SpecLedEx.Coverage.Snapshot.scope_modules/0"
    - "SpecLedEx.Coverage.Snapshot.take/2"
    - "SpecLedEx.Coverage.Snapshot.native_snapshot/1"
    - "SpecLedEx.Coverage.Snapshot.classic_snapshot/1"
    - "SpecLedEx.Coverage.Snapshot.diff/2"
    - "SpecLedEx.Coverage.Store.write/2"
    - "SpecLedEx.Coverage.Store.read/1"
    - "SpecLedEx.Coverage.Store.build_envelope/1"
    - "SpecLedEx.Coverage.Store.write_v2/2"
    - "SpecLedEx.Coverage.Store.read_v2/1"
    - "SpecLedEx.Coverage.Store.read_status/1"
    - "Mix.Tasks.Spec.Cover.Test.run/1"
    - "SpecLedEx.Coverage.Aggregate.ingest/2"
    - "SpecLedEx.Coverage.MfaKey.format/1"
    - "SpecLedEx.Coverage.MfaKey.parse/1"
  implementation:
    - "SpecLedEx.Coverage.Formatter.init/1"
    - "SpecLedEx.Coverage.Store.build_records/1"
    - "SpecLedEx.Coverage.cover_modules_safe/0"
decisions:
  - specled.decision.serialized_per_test_coverage
  - specled.decision.aggregate_first_spec_coverage
```

## Requirements

```yaml spec-requirements
- id: specled.coverage_capture.serialized_run
  statement: >-
    `mix spec.cover.test --per-test` shall call
    `ExUnit.configure(async: false)` and
    `Application.put_env(:ex_unit, :async, false)` before loading any test
    module, and shall arm `SpecLedEx.Coverage.Formatter` via the
    `:specled_ex, :spec_cover_run` seam.
  priority: must
  stability: evolving
- id: specled.coverage_capture.per_test_async_contamination
  statement: >-
    Under `mix spec.cover.test --per-test`, a test file containing the
    literal pragma `async: true` genuinely runs concurrently despite the
    global `ExUnit.configure(async: false)` default and corrupts serialized
    per-test `:cover` attribution; this is a user bug, so the task shall
    exit non-zero naming every such file before running the suite.
  priority: must
  stability: evolving
- id: specled.coverage_capture.per_test_allow_async_degrade
  statement: >-
    `mix spec.cover.test --per-test --allow-async` shall degrade async
    contamination instead of failing: the suite still runs and the task
    still exits 0, but stderr carries a warning naming the contaminated
    files.
  priority: must
  stability: evolving
- id: specled.coverage_capture.default_aggregate_run
  statement: >-
    By default (no `--per-test` flag), `mix spec.cover.test` shall run `mix
    test --cover --export-coverage specled` with no custom formatter
    registered and no async configuration changed. Guarded by the existence
    of the exported `.coverdata` file, it shall then ingest that file via
    `SpecLedEx.Coverage.Aggregate.ingest/2` and persist the resulting v2
    envelope via `SpecLedEx.Coverage.Store.write_v2/2` at
    `SpecLedEx.Coverage.Store.default_path/0`, exiting 0 with
    `Store.read_status/1` reporting `{:ok, stats}`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.default_aggregate_red_suite_passthrough
  statement: >-
    When the wrapped `mix test` suite fails, `mix spec.cover.test`'s exit
    code shall pass through that failing status (non-zero) even though its
    real, non-placeholder exported coverage is still ingested — a successful
    ingest shall never overwrite a failing suite's exit code back to 0.
  priority: must
  stability: evolving
- id: specled.coverage_capture.default_aggregate_empty_refusal
  statement: >-
    When the wrapped `mix test` suite ran to completion but its exported
    coverage carries zero cover-compiled modules (or ingestion is otherwise
    refused), `mix spec.cover.test` shall exit non-zero naming the refusal
    reason, and `Store.read_status/1` on the target artifact path shall
    return `{:refused, ...}`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_snapshot_fn_di
  statement: >-
    SpecLedEx.Coverage.Formatter shall accept a `snapshot_fn` option,
    resolved only once armed (see
    `specled.coverage_capture.formatter_arming_seam`). `snapshot_fn` is
    `([module()] -> %{module() => [{line, count}]})`: production default
    dispatches to `SpecLedEx.Coverage.Snapshot.take(Snapshot.runtime_mode(),
    modules)`, so it takes a whole-scope module snapshot rather than
    decoding one raw `:cover.analyse/3` result per call. Tests inject a
    stub via the arming seam.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_arming_seam
  statement: >-
    SpecLedEx.Coverage.Formatter's `init/1` shall be inert by default:
    when `Application.get_env(:specled_ex, :spec_cover_run)` is unset or
    `false`, it prints one stderr notice and returns `{:ok, :disabled}`,
    after which every ExUnit event is handled as a no-op. Only `mix
    spec.cover.test --per-test` arms it, via
    `Application.put_env(:specled_ex, :spec_cover_run, true)` set before
    installing the formatter. `init/1`'s own argument is never a trusted
    config source — ExUnit forwards its entire `:ex_unit` application
    environment as that argument to every formatter it starts. Once
    armed, formatter config (`snapshot_fn`, `modules_fn`, `artifact_path`)
    is resolved only from the `:specled_ex` arming value itself, never
    from `init/1`'s argument.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_no_fabrication
  statement: >-
    The formatter shall never fabricate a per-test line hit. On
    `suite_started` it takes a baseline module snapshot; on each
    `test_finished` it takes a new snapshot and diffs it against the
    previous boundary snapshot via `SpecLedEx.Coverage.Snapshot.diff/2`
    (`specled.coverage_capture.snapshot_diff_strictly_increased`) — only a
    strictly-increased count becomes a hit for that test. An unchanged
    count is simply "not hit this test," never a placeholder; a
    strictly-decreased count is a `"counters externally harvested"`
    diagnostic (`specled.coverage_capture.snapshot_negative_delta_diagnostic`),
    never a fabricated negative hit. Diagnostics increment a per-run count,
    surfaced via one stderr notice at `suite_finished` whenever that count
    is non-zero, and mark the flushed v2 envelope `degraded: true`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.snapshot_runtime_mode
  statement: >-
    SpecLedEx.Coverage.Snapshot.runtime_mode/0 shall return `:native` when
    `:code.coverage_support/0` reports true, otherwise `:classic`, and
    shall never hard-gate on a specific OTP release (maintainer decision 4:
    recommend OTP >= 27.2 for the native path, never require it).
    `native_snapshot/1` shall read each module's line counts via
    `:code.get_coverage(:line, Module)` inside a per-module try/catch,
    treating a module that is not loaded or was never cover-compiled
    (`ArgumentError` from the BIF) as `[]` for that module rather than
    aborting the snapshot. `classic_snapshot/1` shall read each module's
    line counts via `:cover.analyse(Module, :calls, :line)` looped per
    module in scope rather than one whole-table `:cover.analyse(:_, :calls,
    :line)` call, normalizing both engines' output to the same `%{module()
    => [{line, count}]}` shape.
  priority: must
  stability: evolving
- id: specled.coverage_capture.snapshot_diff_strictly_increased
  statement: >-
    SpecLedEx.Coverage.Snapshot.diff/2 shall return `{hits_by_module,
    diagnostics}` from two module snapshots: a line is included in
    `hits_by_module` only when its count strictly increased relative to
    the previous snapshot (a module or line absent from the previous
    snapshot defaults its baseline count to `0`); an unchanged count
    contributes nothing.
  priority: must
  stability: evolving
- id: specled.coverage_capture.snapshot_negative_delta_diagnostic
  statement: >-
    SpecLedEx.Coverage.Snapshot.diff/2 shall never turn a strictly-decreased
    count into a negative or garbage hit. Each such occurrence is recorded
    as a `%{reason: :counters_externally_harvested, module:, line:, prev:,
    curr:}` diagnostic instead — read-only invariant: this module never
    calls `:cover.reset/0` or `:code.reset_coverage/1` itself, so a
    decrease can only mean something else drained the shared counters
    between two of this module's own snapshots.
  priority: must
  stability: evolving
- id: specled.coverage_capture.per_test_v2_envelope
  statement: >-
    On `suite_finished`, the formatter shall persist the `--per-test`
    artifact as a v2 envelope (`mode: :per_test`) via
    `SpecLedEx.Coverage.Store.write_v2/2`, whose `:payload` is the
    unchanged v1-shaped record list (`%{test_id, file, lines_hit, tags,
    test_pid}`) and whose `:files` is that payload's distinct, sorted file
    set. The envelope's `:degraded` field shall be `true` when any
    captured test's tags carried `async: true`, or when any
    `snapshot_negative_delta_diagnostic` occurred during the run,
    otherwise `false`. When the payload carries no records at all, the
    formatter shall not write an artifact (mirroring
    `Store.write_v2/2`'s empty-files refusal) and shall print one stderr
    notice.
  priority: must
  stability: evolving
- id: specled.coverage_capture.cumulative_parity
  statement: >-
    Arming the `--per-test` formatter (either snapshot engine) shall never
    change the coverage totals `mix test --cover` itself exports: decoding
    the exported `.coverdata` from a plain `mix test --cover
    --export-coverage <name>` run and from a `mix spec.cover.test
    --per-test --export-coverage <name>` run of the same suite shall yield
    identical per-module, per-line call counts.
  priority: must
  stability: evolving
- id: specled.coverage_capture.keyed_by_test_pid
  statement: >-
    The formatter's ETS row key shall default to `{module, name}` — ExUnit
    does not expose a test's runtime pid inside `test.tags`, so ExUnit
    itself never supplies one by default; a `test_pid`-keyed row exists
    only when the test opts in via `@tag test_pid: self()`. Either key is
    unique per test under serialized (non-`async: true`) execution, so
    interleaved `test_finished` events for different tests cannot collide
    on the same ETS row. Key uniqueness does not by itself guarantee
    exclusive attribution: the formatter's snapshot for test N is taken
    lazily inside its own `test_finished` `GenServer.cast` handler, and
    `ExUnit.Runner` does not wait for that cast before starting test N+1,
    so the two tests' underlying `:cover`/native counter progress can
    still interleave (`specled_-cpw`). Per-test attribution is therefore
    observed/approximate, never exact, independent of key choice — see
    `specled.decision.aggregate_first_spec_coverage`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.anonymous_ets
  statement: >-
    The formatter shall use an anonymous ETS table
    (`:ets.new(:anon, [:public, :set])`) for per-test state. No named
    ETS tables shall be used — parallel formatter instances in unit
    tests must not collide on a name.
  priority: must
  stability: evolving
- id: specled.coverage_capture.artifact_path
  statement: >-
    SpecLedEx.Coverage.Store shall keep the v1 record schema — `test_id`,
    `file`, `lines_hit`, `tags`, `test_pid`, with no in-band version field
    — available via `build_records/1`/`write/2`/`read/1` for test
    authoring and as the shape of a v2 `:per_test` envelope's `:payload`.
    The artifact `mix spec.cover.test --per-test` actually writes to
    `.spec/_coverage/per_test.coverdata` shall be that versioned v2
    envelope (`specled.coverage_capture.per_test_v2_envelope`), which does
    carry an in-band `version` field — superseding this requirement's
    original "no in-band version field" claim for the production write
    path (see `specled.decision.aggregate_first_spec_coverage`).
  priority: must
  stability: evolving
- id: specled.coverage_capture.store_split
  statement: >-
    SpecLedEx.Coverage.Store shall be a separate module that reads
    `.spec/_coverage/per_test.coverdata` and exposes a
    `build_records/1` helper that constructs the record-list binary
    from Elixir data for test authoring. Triangulation shall consume
    the store without instantiating a formatter.
  priority: must
  stability: evolving
- id: specled.coverage_capture.integration_case
  statement: >-
    SpecLedEx.IntegrationCase shall provide `run_fixture_mix_test(root,
    args)` that uses `System.cmd/3` to compile and run the fixture in a
    child BEAM, preventing contamination of the outer `:cover` state.
  priority: must
  stability: evolving
- id: specled.coverage_capture.store_v2_envelope
  statement: >-
    SpecLedEx.Coverage.Store shall additionally expose a versioned v2
    envelope container (`build_envelope/1`, `write_v2/2`, `read_v2/1`,
    `read_status/1`) targeting the same on-disk path as the v1 record list.
    `write_v2/2` shall refuse (`{:error, :empty_files}`) an envelope whose
    `:files` is empty, and shall (re)write a `last_run.status` sidecar next
    to the artifact on every call (success or refusal), readable via
    `read_status/1` as `{:ok, stats} | {:refused, reason}`. This is
    additive: `write/2` and `read/1` (v1) are unchanged, and existing
    callers (Formatter, triangulation, review) keep their current behavior
    until their own tickets migrate them to v2.
  priority: must
  stability: evolving
- id: specled.coverage_capture.store_v2_legacy_rejection
  statement: >-
    `SpecLedEx.Coverage.Store.read_v2/1` shall return `{:ok, envelope}` for
    a well-formed v2 envelope, `{:error, :legacy_artifact, message}` (with
    `message` naming the re-run command `mix spec.cover.test`) when the
    artifact decodes as a pre-v2 (v1) list, and `{:error, :invalid_artifact}`
    for any other undecodable or malformed content. Per Decision 5, legacy
    artifacts are never auto-migrated or deleted.
  priority: must
  stability: evolving
- id: specled.coverage_capture.aggregate_ingest
  statement: >-
    `SpecLedEx.Coverage.Aggregate.ingest/2` shall stop, restart, and import
    an exported `.coverdata` file into `:cover` (never `:cover.reset/0`),
    run two analyse passes per module (`:coverage, :line` and `:coverage,
    :function`), map each covered module to a repo-relative source path,
    and return `{:ok, envelope}` where `envelope` is a v2 envelope
    (`SpecLedEx.Coverage.Store.build_envelope/1`) with `:mode` `:aggregate`.
    Modules whose source cannot be mapped under the given root are excluded
    from `:files` and `:mfas` and counted toward `envelope.degraded`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.aggregate_empty_coverage
  statement: >-
    `SpecLedEx.Coverage.Aggregate.ingest/2` shall return
    `{:error, :empty_coverage}` when the imported `.coverdata` carries zero
    cover-compiled or imported modules, without writing any envelope
    itself. A caller (`mix spec.cover.ingest`) that still records this
    outcome via `Store.write_v2/2` on an empty envelope gets the standard
    `{:error, :empty_files}` refusal, so `Store.read_status/1` on the
    target path reports `{:refused, ...}` rather than leaving no sidecar
    at all.
  priority: must
  stability: evolving
- id: specled.coverage_capture.aggregate_unmapped_degraded
  statement: >-
    When `SpecLedEx.Coverage.Aggregate.ingest/2` cannot map a covered
    module to a repo-relative source path (the module is not loaded, has
    no `:source` compile metadata, or its source lies outside `:root`),
    that module's data shall be excluded from `envelope.files` and
    `envelope.mfas` and counted toward `envelope.degraded`, without
    aborting the ingest as long as at least one other module is
    mappable.
  priority: must
  stability: evolving
- id: specled.coverage_capture.mfa_key_round_trip
  statement: >-
    `SpecLedEx.Coverage.MfaKey.format/1` and `parse/1` shall round-trip:
    for every `{module, function, arity}` triple, `parse(format(mfa)) ==
    {:ok, mfa}`. This is the string format `SpecLedEx.Coverage.Aggregate`
    writes into envelope `:mfas` entries and the one downstream consumers
    (coverage triangulation) parse back.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.coverage_capture.scenario.formatter_stub_snapshot
  given:
    - "a formatter initialized with `snapshot_fn: stub_fn` (`[module()] -> %{module() => [{line, count}]}`)"
    - "a `suite_started` event establishing the baseline, then a simulated ExUnit `test_finished` event for test `\"my_test\"` from pid P"
  when:
    - the formatter handles the events
  then:
    - stub_fn was called once for the baseline and once for the test
    - the per-test record under P contains the diffed, file-compacted hits and the test tags
  covers:
    - specled.coverage_capture.formatter_snapshot_fn_di
    - specled.coverage_capture.keyed_by_test_pid
- id: specled.coverage_capture.scenario.formatter_disarmed_by_default
  given:
    - "the formatter is registered in `:formatters` but `Application.get_env(:specled_ex, :spec_cover_run)` is unset"
  when:
    - "`init/1` runs, then every ExUnit event is dispatched to it"
  then:
    - "`init/1` returns `{:ok, :disabled}` after printing exactly one stderr notice"
    - "every event handles as `{:noreply, :disabled}`; no artifact is written"
  covers:
    - specled.coverage_capture.formatter_arming_seam
- id: specled.coverage_capture.scenario.formatter_no_fabrication
  given:
    - "a baseline snapshot and a test snapshot where one line's count is unchanged and another's has strictly decreased"
  when:
    - the formatter diffs the two snapshots for that test
  then:
    - "the unchanged line is not recorded as a hit (no placeholder)"
    - "the decreased line is counted as a `counters_externally_harvested` diagnostic, surfaced via stderr at `suite_finished`, and marks the envelope `degraded: true` — never recorded as a negative hit"
  covers:
    - specled.coverage_capture.formatter_no_fabrication
    - specled.coverage_capture.snapshot_negative_delta_diagnostic
- id: specled.coverage_capture.scenario.snapshot_runtime_mode_dispatch
  given:
    - "the current runtime's `:code.coverage_support/0` value"
  when:
    - "`Snapshot.runtime_mode/0` is called"
  then:
    - "it returns `:native` when coverage_support is true, `:classic` otherwise, never raising regardless of OTP release"
  covers:
    - specled.coverage_capture.snapshot_runtime_mode
- id: specled.coverage_capture.scenario.snapshot_diff_strictly_increased
  given:
    - "two module snapshots where one line's count increased, one is unchanged, and one is absent from the previous snapshot"
  when:
    - "`Snapshot.diff/2` runs over them"
  then:
    - "the increased and newly-present lines appear in `hits_by_module`; the unchanged line does not"
  covers:
    - specled.coverage_capture.snapshot_diff_strictly_increased
- id: specled.coverage_capture.scenario.per_test_v2_envelope_degraded
  given:
    - "a `--per-test` run where one captured test's tags carried `async: true`"
  when:
    - "the formatter flushes on `suite_finished`"
  then:
    - "the written v2 envelope has `mode: :per_test`, a `:payload` of v1-shaped records, and `degraded: true`"
  covers:
    - specled.coverage_capture.per_test_v2_envelope
- id: specled.coverage_capture.scenario.cumulative_parity_tripwire
  given:
    - "a child-BEAM fixture run once as plain `mix test --cover --export-coverage <a>` and once as `mix spec.cover.test --per-test --export-coverage <b>`"
  when:
    - "both exported `.coverdata` files are decoded via `:cover.import/1` + per-module `:cover.analyse/3`"
  then:
    - "the decoded per-module, per-line call counts are identical between the two runs"
  covers:
    - specled.coverage_capture.cumulative_parity
- id: specled.coverage_capture.scenario.store_round_trip
  given:
    - "a list of Elixir records built via `Coverage.Store.build_records/1`"
    - those records written via `Coverage.Store.write/2` to a temp path
  when:
    - `Coverage.Store.read/1` is called with the same path
  then:
    - the returned list is byte-equal to the input records (order preserved)
  covers:
    - specled.coverage_capture.store_split
    - specled.coverage_capture.artifact_path
- id: specled.coverage_capture.scenario.store_v2_round_trip
  given:
    - "a v2 envelope built via `Coverage.Store.build_envelope/1` with a non-empty `:files` list"
  when:
    - "`Coverage.Store.write_v2/2` writes it to a temp path, then `Coverage.Store.read_v2/1` reads that same path"
  then:
    - "the decoded envelope is identical to the one written"
    - "`Coverage.Store.read_status/1` on the same path returns `{:ok, stats}`"
  covers:
    - specled.coverage_capture.store_v2_envelope
- id: specled.coverage_capture.scenario.store_v2_legacy_and_invalid_rejection
  given:
    - "a v1-format artifact (a bare list) written at a path"
    - "a garbage-bytes artifact written at another path"
  when:
    - "`Coverage.Store.read_v2/1` is called on each path"
  then:
    - "the v1 artifact yields `{:error, :legacy_artifact, message}` where `message` names `mix spec.cover.test`"
    - "the garbage artifact yields `{:error, :invalid_artifact}`"
  covers:
    - specled.coverage_capture.store_v2_legacy_rejection
- id: specled.coverage_capture.scenario.spec_cover_test_per_test_forces_serial
  given:
    - "a child-BEAM fixture with no `async: true` test modules"
  when:
    - "mix spec.cover.test --per-test runs on the fixture (via IntegrationCase)"
  then:
    - "the run completes, the formatter is armed via the :specled_ex seam"
    - "`.spec/_coverage/per_test.coverdata` exists with at least one record per test"
  covers:
    - specled.coverage_capture.serialized_run
    - specled.coverage_capture.integration_case
- id: specled.coverage_capture.scenario.spec_cover_test_per_test_async_contamination
  given:
    - "a child-BEAM fixture with one `async: true` test module"
  when:
    - "mix spec.cover.test --per-test runs on the fixture without --allow-async"
  then:
    - "the task exits non-zero naming the async: true test file"
  covers:
    - specled.coverage_capture.per_test_async_contamination
- id: specled.coverage_capture.scenario.spec_cover_test_per_test_allow_async_degrades
  given:
    - "the same async: true fixture"
  when:
    - "mix spec.cover.test --per-test --allow-async runs on the fixture"
  then:
    - "the run proceeds and exits 0"
    - "stderr carries a degraded-run warning naming the async: true test file"
    - "`.spec/_coverage/per_test.coverdata` is still written"
  covers:
    - specled.coverage_capture.per_test_allow_async_degrade
- id: specled.coverage_capture.scenario.spec_cover_test_default_aggregate
  given:
    - "a child-BEAM fixture whose tests exercise real application code"
  when:
    - "mix spec.cover.test runs on the fixture with no flags"
  then:
    - "no formatter is registered and async config is untouched"
    - "the exported `.coverdata` is ingested into a v2 `:aggregate` envelope at the default artifact path"
    - "the task exits 0 and `Store.read_status/1` returns `{:ok, stats}`"
  covers:
    - specled.coverage_capture.default_aggregate_run
- id: specled.coverage_capture.scenario.spec_cover_test_red_suite_passthrough
  given:
    - "a child-BEAM fixture with one failing test that still exercises application code"
  when:
    - "mix spec.cover.test runs on the fixture with no flags"
  then:
    - "the exported `.coverdata` still exists and is ingested (real coverage, not a placeholder)"
    - "the task's exit code passes through the failing `mix test` status (non-zero) rather than being overwritten to 0 by the successful ingest"
  covers:
    - specled.coverage_capture.default_aggregate_red_suite_passthrough
- id: specled.coverage_capture.scenario.spec_cover_test_empty_coverage_refusal
  given:
    - "a child-BEAM fixture whose test suite exercises no application module"
  when:
    - "mix spec.cover.test runs on the fixture with no flags"
  then:
    - "the exported `.coverdata` carries zero cover-compiled modules"
    - "the task exits non-zero naming the empty-coverage refusal"
    - "`Store.read_status/1` on the target artifact path returns `{:refused, ...}`"
  covers:
    - specled.coverage_capture.default_aggregate_empty_refusal
- id: specled.coverage_capture.scenario.aggregate_ingest_child_beam
  given:
    - "a child-BEAM fixture project compiled and run via `mix test --cover --export-coverage <name>`, producing a real `.coverdata` file"
  when:
    - "`SpecLedEx.Coverage.Aggregate.ingest/2` ingests that `.coverdata` file"
  then:
    - "the returned envelope has nonempty `:files` and `:mfas`"
    - "the envelope persists via `Store.write_v2/2` and reads back identically via `Store.read_v2/1`"
  covers:
    - specled.coverage_capture.aggregate_ingest
- id: specled.coverage_capture.scenario.aggregate_ingest_empty_coverage
  given:
    - "an exported `.coverdata` file with zero cover-compiled modules"
  when:
    - "`SpecLedEx.Coverage.Aggregate.ingest/2` ingests that file via `mix spec.cover.ingest`"
  then:
    - "the ingest is refused with a message naming empty coverage"
    - "`Store.read_status/1` on the target path returns `{:refused, ...}`"
  covers:
    - specled.coverage_capture.aggregate_empty_coverage
- id: specled.coverage_capture.scenario.aggregate_ingest_unmapped_degraded
  given:
    - "a child-BEAM fixture with two covered modules, one of which has its compiled `.beam` removed after export so its source cannot be mapped"
  when:
    - "`SpecLedEx.Coverage.Aggregate.ingest/2` ingests the resulting `.coverdata`"
  then:
    - "the ingest still succeeds, with the mappable module's files/mfas present"
    - "the unmapped module's mfas are absent and `envelope.degraded` is `true`"
  covers:
    - specled.coverage_capture.aggregate_unmapped_degraded
- id: specled.coverage_capture.scenario.mfa_key_format_parse_round_trip
  given:
    - "an MFA triple `{Module, :fun, 2}`"
  when:
    - "the triple is formatted via `MfaKey.format/1` then parsed via `MfaKey.parse/1`"
  then:
    - "the parsed result is `{:ok, {Module, :fun, 2}}`"
  covers:
    - specled.coverage_capture.mfa_key_round_trip
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.formatter_snapshot_fn_di
    - specled.coverage_capture.keyed_by_test_pid
    - specled.coverage_capture.anonymous_ets
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.formatter_arming_seam
    - specled.coverage_capture.formatter_no_fabrication
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.store_split
    - specled.coverage_capture.artifact_path
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.store_v2_envelope
    - specled.coverage_capture.store_v2_legacy_rejection
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.serialized_run
    - specled.coverage_capture.per_test_async_contamination
    - specled.coverage_capture.per_test_allow_async_degrade
    - specled.coverage_capture.integration_case
    - specled.coverage_capture.default_aggregate_run
    - specled.coverage_capture.default_aggregate_red_suite_passthrough
    - specled.coverage_capture.default_aggregate_empty_refusal
    - specled.coverage_capture.per_test_v2_envelope
    - specled.coverage_capture.cumulative_parity
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.aggregate_ingest
    - specled.coverage_capture.aggregate_empty_coverage
    - specled.coverage_capture.aggregate_unmapped_degraded
    - specled.coverage_capture.mfa_key_round_trip
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.snapshot_runtime_mode
    - specled.coverage_capture.snapshot_diff_strictly_increased
    - specled.coverage_capture.snapshot_negative_delta_diagnostic
```
