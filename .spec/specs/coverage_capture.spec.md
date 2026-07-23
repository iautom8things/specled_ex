# Per-Test Coverage Capture

Serialized per-test coverage collection via a custom ExUnit formatter and a
dedicated Mix task.

## Intent

`:cover` has no per-pid surface and races under `async: true`. We do not try to
make async-safe attribution work; instead, a new `mix spec.cover.test` task
wraps `mix test --cover` and forces `ExUnit.configure(async: false)` globally
before any test module loads. The formatter snapshots coverage per-test keyed
by `test_pid`, using anonymous ETS (so multiple formatters can coexist in
tests). `mix test --cover` continues to work in its traditional cumulative
mode; only `mix spec.cover.test` produces the per-test artifact at
`.spec/_coverage/per_test.coverdata`.

```yaml spec-meta
id: specled.coverage_capture
kind: workflow
status: active
summary: `mix spec.cover.test` task + ExUnit formatter that captures per-test line coverage serialized; Store reads/writes `.spec/_coverage/per_test.coverdata`.
surface:
  - lib/specled_ex/coverage.ex
  - lib/specled_ex/coverage/formatter.ex
  - lib/specled_ex/coverage/store.ex
  - lib/mix/tasks/spec.cover.test.ex
  - test/specled_ex/coverage/formatter_test.exs
  - test/specled_ex/coverage/store_test.exs
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
    `mix spec.cover.test` shall call
    `ExUnit.configure(async: false)` and
    `Application.put_env(:ex_unit, :async, false)` before loading any
    test module. Any test that sets `async: true` during a
    spec.cover.test run is a user bug; the task shall log a warning on
    exit naming all such test files.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_snapshot_fn_di
  statement: >-
    SpecLedEx.Coverage.Formatter shall accept a `snapshot_fn` option at
    init. Production default is `&:cover.analyse/1`. Tests pass a stub.
    The formatter shall never call `:cover.analyse/1` directly; it
    always routes through the injected function.
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
- id: specled.coverage_capture.scenario.spec_cover_test_forces_serial
  given:
    - "test/fixtures/sample_project with one `async: true` test module"
  when:
    - mix spec.cover.test runs on the fixture (via IntegrationCase)
  then:
    - "the run completes without :cover races"
    - "stderr carries a warning naming the async: true test file"
    - "`.spec/_coverage/per_test.coverdata` exists with at least one record per test"
  covers:
    - specled.coverage_capture.serialized_run
    - specled.coverage_capture.integration_case
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
    - specled.coverage_capture.integration_case
```
