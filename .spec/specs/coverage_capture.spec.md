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
snapshots coverage per-test keyed by `test_pid` using anonymous ETS (so
multiple formatters can coexist in tests). Under `--per-test`, a test file
that declares `async: true` genuinely does run concurrently despite the
global default and corrupts serialized attribution, so the task exits
non-zero naming it unless `--allow-async` degrades the run instead. `mix test
--cover` continues to work in its traditional cumulative mode; only `mix
spec.cover.test --per-test` produces the per-test artifact at
`.spec/_coverage/per_test.coverdata` (the default aggregate mode's v2
envelope targets the same path).

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
  - lib/specled_ex/coverage/store.ex
  - lib/specled_ex/coverage/aggregate.ex
  - lib/specled_ex/coverage/mfa_key.ex
  - lib/mix/tasks/spec.cover.test.ex
  - lib/mix/tasks/spec.cover.ingest.ex
  - test/specled_ex/coverage/formatter_test.exs
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
    `specled.coverage_capture.formatter_arming_seam`). Production default
    calls `:cover.analyse(target, :coverage, :line)` — explicit line-level
    granularity. The bare arity-1 `:cover.analyse/1` form defaults to
    function-level granularity and is never called: line-level is the only
    granularity this formatter can honestly attribute to a source line.
    Tests inject a stub via the arming seam.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_arming_seam
  statement: >-
    SpecLedEx.Coverage.Formatter's `init/1` shall be inert by default:
    when `Application.get_env(:specled_ex, :spec_cover_run)` is unset or
    `false`, it prints one stderr notice and returns `{:ok, :disabled}`,
    after which every ExUnit event is handled as a no-op. Only `mix
    spec.cover.test` arms it, via
    `Application.put_env(:specled_ex, :spec_cover_run, true)` set before
    installing the formatter. `init/1`'s own argument is never a trusted
    config source — ExUnit forwards its entire `:ex_unit` application
    environment as that argument to every formatter it starts. Once
    armed, formatter config (`snapshot_fn`, `snapshot_target`,
    `modules_fn`, `artifact_path`) is resolved only from the
    `:specled_ex` arming value itself, never from `init/1`'s argument.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_no_fabrication
  statement: >-
    The formatter shall never fabricate a record for a snapshot entry it
    cannot attribute to a source line. A function-level (MFA-shaped)
    entry, a snapshot with no line-level entries at all, and any snapshot
    shape other than `{:result, ok_results, failed}` are never turned
    into a placeholder or a `{file, 0}` record. Each such occurrence
    increments a per-flush decode-error count, surfaced via one stderr
    notice at `suite_finished` whenever that count is non-zero.
  priority: must
  stability: evolving
- id: specled.coverage_capture.keyed_by_test_pid
  statement: >-
    The formatter shall key per-test state by `test_pid` as reported in
    the ExUnit event. The per-test record shall carry
    `{snapshot, tags, test_id}`. Interleaved events from different
    tests cannot collide because each serialized run has a unique
    test_pid at any moment.
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
    The per-test coverage artifact shall be written to
    `.spec/_coverage/per_test.coverdata` as ETF encoding a list of
    records with fields `test_id`, `file`, `lines_hit`, `tags`, and
    `test_pid`. The schema version is implicit in `hasher_version`-style
    bumps; no in-band version field.
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
    - "a formatter initialized with `snapshot_fn: stub_fn`"
    - a simulated ExUnit `test_finished` event for test `"my_test"` from pid P
  when:
    - the formatter handles the event
  then:
    - stub_fn was called exactly once with the cover module set
    - the per-test record under P contains the stub's return value and the test tags
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
    - "a snapshot containing a function-level (MFA-shaped) entry, or one that is not a `{:result, _, _}` tuple at all"
  when:
    - the formatter flushes on `suite_finished`
  then:
    - "no `{file, 0}` or placeholder record is written for that entry"
    - "the occurrence is counted and surfaced as a decode error via stderr"
  covers:
    - specled.coverage_capture.formatter_no_fabrication
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
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.aggregate_ingest
    - specled.coverage_capture.aggregate_empty_coverage
    - specled.coverage_capture.aggregate_unmapped_degraded
    - specled.coverage_capture.mfa_key_round_trip
```
