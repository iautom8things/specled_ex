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
`ExUnit.configure(async: false)` and arms `SpecLedEx.Coverage.Formatter` as
a suite-lifecycle auditor (inventory + flush; no per-test snapshots —
`specled.coverage_capture.formatter_auditor`). Exclusive per-test
attribution comes from the synchronous boundary hook
(`setup {SpecLedEx.Coverage, :per_test_boundary}` or `use SpecLedEx.Case`):
one initial head snapshot, then a tail snapshot in each `on_exit`, which
`ExUnit.Runner` awaits before spawning the next test. Each tail is reused as
the next test's head. Hooked tests' `[head, tail]` windows are therefore
disjoint, but after the first hooked test they include everything since the
prior hooked tail: serialized runner / `setup_all` work and any intervening
unhooked tests. Attribution is exact within that chained window up to escaped
processes. Unhooked tests never fail the run:
they produce no row of their own; coverage not absorbed by a later chained
hooked window remains in the run's aggregate remainder. The envelope is
`degraded: true`, and one per-module stderr notice names the setup line to
add (`specled.coverage_capture.unhooked_degrade`,
`specled.coverage_capture.unhooked_remediation_notice`). Inventory is
keyed by `{module, name}` by default — ExUnit does not expose a test's
runtime pid inside `test.tags`, so a `test_pid`-keyed inventory row exists
only when the test itself opts in via `@tag test_pid: self()`. Under
`--per-test`, a test file that declares `async: true` genuinely does run
concurrently despite the global default and corrupts serialized
attribution, so the task exits non-zero naming it unless `--allow-async`
degrades the run instead. `mix test --cover` continues to work in its
traditional cumulative mode; only `mix spec.cover.test --per-test`
produces the per-test artifact at `.spec/_coverage/per_test.coverdata`
(the default aggregate mode's v2 envelope targets the same path). See
`specled.decision.per_test_sync_boundary` (supersedes the race-bound claim
in `specled.decision.aggregate_first_spec_coverage`).

`mix spec.cover.test --per-test` resident-loads
`SpecLedEx.Coverage.Snapshot` alongside `Formatter`, `Store`, `Coverage`,
`Boundary`, and `SpecLedEx.Case` in its child BEAM because a fixture's own
`app.config` rewrite would otherwise evict the parent's lazily-loaded ebin
before `suite_started` or a hooked test's boundary setup could reach it. The
task also creates a public anonymous ETS `:boundary_table` and arms it via the
keyword form of the `:specled_ex, :spec_cover_run` seam.

The formatter is inert unless armed: registering it in `:formatters` is not
by itself enough to run it (ExUnit forwards its entire `:ex_unit` application
environment to every formatter it starts, so trusting a formatter's own init
argument would let unrelated config smuggle in). Only `mix spec.cover.test`
arms it, via a dedicated `:specled_ex` application-env seam. Once armed, the
formatter never fabricates a record for a snapshot entry it cannot attribute
to a real source line — unrecognized or function-level snapshot shapes are
counted and surfaced as decode errors instead.

`snapshot_test.exs`'s own fixture-compile helper (`cover_snapshot_in_child/1`)
mirrors the same contamination-avoidance discipline
`SpecLedEx.IntegrationCase.run_fixture_mix_test/2` documents
(`specled.coverage_capture.integration_case`): compiling a fresh fixture
module, cover-compiling it, exercising it, and reading its
`native_snapshot/1`/`classic_snapshot/1` result all happen in a separate
`elixir -e` child process (its own `:cover` coordinator), never the host test
BEAM's shared `:cover` server an outer `mix test --cover` run depends on. An
earlier revision did this in-process and deleted the fixture's tmp source
directory on `on_exit`; the module stayed registered in the host's `:cover`
coordinator after its source was gone, leaking a spurious 100% row into an
outer `mix test --cover` tally and crashing its HTML report generator with
`{:no_source_code_found, _}` — the same class of contamination
`integration_case` exists to prevent, just via a bespoke `elixir -e`
invocation rather than a scaffolded `mix` fixture project (there is no `mix`
task to run here, only two library functions to call against a cover-compiled
module).

```yaml spec-meta
id: specled.coverage_capture
kind: workflow
status: active
summary: `mix spec.cover.test` task + ExUnit formatter that captures per-test line coverage serialized; Store reads/writes `.spec/_coverage/per_test.coverdata`.
surface:
  - lib/specled_ex/coverage.ex
  - lib/specled_ex/coverage/arming.ex
  - lib/specled_ex/coverage/boundary.ex
  - lib/specled_ex/case.ex
  - lib/specled_ex/coverage/formatter.ex
  - lib/specled_ex/coverage/snapshot.ex
  - lib/specled_ex/coverage/store.ex
  - lib/specled_ex/coverage/aggregate.ex
  - lib/specled_ex/coverage/mfa_key.ex
  - lib/specled_ex/coverage/mfa_lines.ex
  - lib/mix/tasks/spec.cover.test.ex
  - lib/mix/tasks/spec.cover.ingest.ex
  - test/specled_ex/coverage/formatter_test.exs
  - test/specled_ex/coverage/boundary_test.exs
  - test/specled_ex/case_test.exs
  - test/specled_ex/coverage/snapshot_test.exs
  - test/specled_ex/coverage/store_test.exs
  - test/specled_ex/coverage/aggregate_test.exs
  - test/specled_ex/coverage/mfa_key_test.exs
  - test/specled_ex/coverage/mfa_lines_test.exs
  - test/mix/tasks/spec_cover_test_test.exs
  - test_support/specled_ex_integration_case.ex
realized_by:
  api_boundary:
    - "SpecLedEx.Coverage.init/2"
    - "SpecLedEx.Coverage.install/1"
    - "SpecLedEx.Coverage.default_artifact_path/0"
    - "SpecLedEx.Coverage.per_test_boundary/1"
    - "SpecLedEx.Coverage.Boundary.head/1"
    - "SpecLedEx.Coverage.Boundary.tail/2"
    - "SpecLedEx.Case"
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
    - "SpecLedEx.Coverage.Store.load/1"
    - "SpecLedEx.Coverage.Store.read_status/1"
    - "Mix.Tasks.Spec.Cover.Test.run/1"
    - "SpecLedEx.Coverage.Aggregate.ingest/2"
    - "SpecLedEx.Coverage.MfaKey.format/1"
    - "SpecLedEx.Coverage.MfaKey.parse/1"
    - "SpecLedEx.Coverage.MfaLines.index/1"
  implementation:
    - "SpecLedEx.Coverage.Arming.resolve/1"
    - "SpecLedEx.Coverage.Formatter.init/1"
    - "SpecLedEx.Coverage.Store.build_records/1"
    - "SpecLedEx.Coverage.cover_modules_safe/0"
decisions:
  - specled.decision.serialized_per_test_coverage
  - specled.decision.aggregate_first_spec_coverage
  - specled.decision.per_test_sync_boundary
  - specled.decision.coverage_identity_joins
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
    `SpecLedEx.Coverage.Arming.resolve/1` shall be the sole decoder of the
    `:specled_ex, :spec_cover_run` seam for both formatter and boundary
    consumers, returning `{:armed, config}` or `:disarmed`; it shall own the
    private ETS modules-cache key and the shared production defaults for
    `snapshot_fn`, `modules_fn`, and `artifact_path`. A boundary table is
    valid only when it is a live ETS table, defined as
    `:ets.info(tid) != :undefined` (invalid identifiers and deleted tables
    are disarmed).
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
    `suite_started` it takes a baseline module snapshot; on
    `suite_finished` it takes a final whole-scope snapshot and diffs via
    `SpecLedEx.Coverage.Snapshot.diff/2`
    (`specled.coverage_capture.snapshot_diff_strictly_increased`) to
    compute the run-total — only a strictly-increased count becomes a hit.
    An unchanged count is simply "not hit this run," never a placeholder; a
    strictly-decreased count is a `"counters externally harvested"`
    diagnostic (`specled.coverage_capture.snapshot_negative_delta_diagnostic`),
    never a fabricated negative hit. Diagnostics increment a per-run count,
    surfaced via one stderr notice at `suite_finished` whenever that count
    is non-zero, and mark the flushed v2 envelope `degraded: true`.
    Per-test hits themselves come only from boundary windows (see
    `formatter_auditor`); the formatter never invents per-test line hits
    from inventory alone.
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
    test_pid}`) derived exclusively from hooked boundary rows, and whose
    `:files` is the distinct, sorted union of payload files and
    unattributed remainder files. The envelope's `:degraded` field shall
    be `true` when any captured test's tags carried `async: true`, when
    any `snapshot_negative_delta_diagnostic` occurred during the run, or
    when any inventoried test was unhooked (`unhooked_degrade`); otherwise
    `false`. A run with zero hooked rows but a non-empty aggregate
    remainder still writes the (degraded) envelope — empty `:payload` alone
    shall not refuse the write when `:files` is non-empty. The formatter
    shall not write an artifact when `:files` is empty (mirroring
    `Store.write_v2/2`'s empty-files refusal) and shall print one stderr
    notice in that case.
  priority: must
  stability: evolving
- id: specled.coverage_capture.per_test_artifact_freshness
  statement: >-
    After the wrapped suite returns or raises, `mix spec.cover.test
    --per-test` shall require `Store.read_status/1` to report success and
    `Store.read_v2/1` to return an envelope whose `generated_at` is later
    than a timestamp captured immediately before the suite started. A
    missing, refused, invalid, or older artifact shall raise a clear stale
    artifact error, so a formatter failure can never silently reuse the
    previous run's file. A red suite that wrote a fresh artifact shall
    retain its original failing exit rather than gaining a stale-artifact
    failure merely because its tests failed.
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
    The formatter's inventory ETS row key shall default to `{module, name}`
    — ExUnit does not expose a test's runtime pid inside `test.tags`, so
    ExUnit itself never supplies one by default; a `test_pid`-keyed
    inventory row exists only when the test opts in via `@tag test_pid:
    self()`. Either key is unique per test under serialized
    (non-`async: true`) execution, so interleaved `test_finished` events
    for different tests cannot collide on the same inventory row. Boundary
    rows are always keyed by `{module, name}` and matched on flush via
    that stable test key. Per-test attribution for hooked tests is exact
    within the chained window disclosed by
    `specled.decision.per_test_sync_boundary` (including the serialized
    interval preceding later tests and escaped-process leakage); the
    inventory key choice does not itself perform measurement.
  priority: must
  stability: evolving
- id: specled.coverage_capture.anonymous_ets
  statement: >-
    The formatter shall use an anonymous ETS table
    (`:ets.new(:anon, [:public, :set, read_concurrency: true,
    write_concurrency: true])`) for per-test state. No named ETS tables
    shall be used — parallel formatter instances in unit tests must not
    collide on a name.
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
- id: specled.coverage_capture.mfa_lines_index
  statement: >-
    `SpecLedEx.Coverage.MfaLines.index/1` shall return
    `%{module => fun_index | :no_debug_info}` where `fun_index` is
    `%{{fun, arity} => MapSet.t(line)}` derived from
    `:beam_lib.chunks(beam, [:abstract_code])` function-form clause
    annos. Modules without abstract code shall yield `:no_debug_info`
    (surfaced, never silently an empty map). Production caller:
    `SpecLedEx.Review.CoverageClosure.build_v2/2` via
    `CoverageTriangulation.per_test_requirement_reach/3`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.boundary_hook_sync
  statement: >-
    `SpecLedEx.Coverage.Boundary` shall take one initial whole-scope head
    snapshot (`Boundary.head/1`) and a tail snapshot in each test's
    `on_exit` callback (`Boundary.tail/2`), which `ExUnit.Runner` awaits via
    `exec_on_exit/3` before spawning the next test. Each tail shall be
    retained in the boundary ETS table as the next test's head, so the
    `on_exit` closure captures only the test key. The public adopter API is
    `setup {SpecLedEx.Coverage, :per_test_boundary}` (or `use SpecLedEx.Case`).
    The cost is one O(modules × lines) initial snapshot plus one O(modules ×
    lines) snapshot, one `Snapshot.diff/2`, and ETS operations per hooked
    test; no `module_info/1` calls occur on the boundary hot path.
  priority: must
  stability: evolving
- id: specled.coverage_capture.boundary_noop_unarmed
  statement: >-
    `SpecLedEx.Coverage.per_test_boundary/1` and `Boundary.head/1` shall be
    pure no-ops (return `:ok` / `:unarmed`, zero ETS writes, zero snapshot
    calls) when `Application.get_env(:specled_ex, :spec_cover_run)` is unset,
    `false`, `true`, or a keyword list lacking a live `:boundary_table`
    according to the arming resolver's `:ets.info/1` predicate. The wiring
    is therefore safe under plain `mix test`. `per_test_boundary/1` shall
    also tolerate ExUnit `setup_all` contexts that carry `:module` without
    a per-test `:test` key.
  priority: must
  stability: evolving
- id: specled.coverage_capture.case_template
  statement: >-
    `SpecLedEx.Case` shall be an `ExUnit.CaseTemplate` that forwards opts to
    `use ExUnit.Case` and injects `setup {SpecLedEx.Coverage,
    :per_test_boundary}`. Intended for bare `ExUnit.Case` modules;
    Phoenix-style apps compose the setup line into their own case templates
    instead.
  priority: must
  stability: evolving
- id: specled.coverage_capture.boundary_row_exclusive
  statement: >-
    When `mix spec.cover.test --per-test` has armed a `:boundary_table` and a
    hooked test produced a boundary row for its `{module, name}` key,
    `SpecLedEx.Coverage.Formatter.flush/1` shall derive that test's flushed
    record exclusively from the boundary window (compacted via the
    formatter's file map). Unhooked tests (no boundary row) produce no
    per-test payload record. Their coverage remains in the unattributed
    remainder unless a later hooked test's chained window starts at an
    earlier hooked tail and therefore absorbs the intervening unhooked
    execution (`formatter_auditor` / `unhooked_degrade`). There is no
    lazy-capture fallback.
  priority: must
  stability: evolving
- id: specled.coverage_capture.per_test_exclusive_attribution
  statement: >-
    Under `mix spec.cover.test --per-test`, hooked tests' `[head, tail]`
    windows shall be chained and disjoint: `tail(N) == head(N+1)`. The first
    window starts at its setup; each later window also includes activity in
    the serialized runner / `setup_all` interval after the prior tail and
    before the current setup; if unhooked tests ran since the prior hooked
    tail, their execution is part of that interval too. Two hooked tests that
    exercise disjoint functions of a fixture module shall still produce
    disjoint `lines_hit` sets when that between-test interval does not
    execute those functions.
    Attribution is exact within each chained window, qualified by both that
    disclosed between-test interval and processes a test spawns that outlive
    its tail snapshot. Proven by a seeded exclusivity integration test over
    three distinct explicit seeds — never a statistical assertion.
  priority: must
  stability: evolving
- id: specled.coverage_capture.envelope_meta
  statement: >-
    `SpecLedEx.Coverage.Store.build_envelope/1` shall accept an optional
    `:meta` map (default `%{}`). `read_v2/1` shall tolerate envelopes written
    without `:meta` (older artifacts default `meta: %{}`). When
    `Formatter.flush/1` consumes any boundary row, the written envelope shall
    carry `meta.boundary: true`. When any inventoried test is unhooked, the
    envelope shall carry `meta.unhooked_modules` (sorted module list). When
    the unattributed remainder is non-empty, the envelope shall carry
    `meta.unattributed` as `[{file, sorted_lines}]`. When any boundary or
    run-total hit belongs to a module the suite-start file map cannot resolve,
    the envelope shall carry `meta.unmapped_modules` as a sorted unique module
    list. `write_v2/2` shall tolerate a missing `:meta` on the same terms as
    `read_v2/1` — it is additive, so an envelope without it is well-formed —
    and shall reject a present-but-non-map `:meta` as malformed. `read_v2/1`
    shall classify an envelope whose `:meta` key is present but not a map as
    `{:error, :invalid_artifact}`, never as a well-formed envelope with a
    defaulted `meta: %{}`.
  priority: must
  stability: evolving
- id: specled.coverage_capture.write_v2_argument_error_contract
  statement: >-
    Every malformed-envelope rejection in
    `SpecLedEx.Coverage.Store.write_v2/2` shall raise the `ArgumentError` the
    function documents, whichever field is malformed or missing. A caller
    catching the documented exception must never be handed a different
    exception type instead — an optional field read with dot access raises
    `KeyError`, which that caller does not catch and cannot anticipate from
    the docs.
  priority: must
  stability: evolving
- id: specled.coverage_capture.degraded_reasons
  statement: >-
    Whenever the written envelope is `degraded: true`, it shall carry
    `meta.degraded_reasons` — a non-empty list drawn from
    `[:async, :counters_harvested, :unhooked]` recording every cause that
    fired — so consumers never reconstruct the cause from which other meta
    keys happen to be present. `:async` and `:counters_harvested`
    invalidate the hooked windows themselves; `:unhooked` merely omits the
    unhooked tests' coverage. Readers (`Store.degraded_reasons/1`) shall
    treat a degraded envelope without the key as legacy, inferring
    `[:unhooked]` when `meta.unhooked_modules` is present and `[:async]`
    otherwise, and shall return `[]` for a non-degraded envelope.
  priority: must
  stability: evolving
- id: specled.coverage_capture.formatter_auditor
  statement: >-
    Under `mix spec.cover.test --per-test`, `SpecLedEx.Coverage.Formatter`
    shall take no per-test snapshots: `test_finished` records inventory
    only (`test_id`, `test_key`, `module`, `tags`, `test_pid`) and the
    existing `degraded_async?` fold, and only for tests that ran
    (see `never_ran_not_inventoried`). On `suite_finished` it shall take one
    final whole-scope snapshot, compute run-total hits via
    `Snapshot.diff(baseline, final)`, attribute the union of boundary rows
    to per-test payload records, and fold the unattributed remainder
    (line-level set subtraction of attributed from run-total) into
    `meta.unattributed` and `envelope.files`. Because chained heads come
    from the prior hooked tail, intervening unhooked execution may already
    be present in a later boundary row and thus absent from that remainder.
    Boundary payload and remainder compaction shall reuse the same suite-start
    module-to-source map; hit modules missing from that map shall surface in
    `meta.unmapped_modules`. There is no lazy-capture fallback for unhooked
    tests.
  priority: must
  stability: evolving
- id: specled.coverage_capture.unhooked_degrade
  statement: >-
    When any test that ran lacks a boundary row for its `{module, name}`
    key, `Formatter.flush/1` shall never fail the run for that reason: the
    unhooked test contributes no per-test payload record of its own; its
    coverage remains in the unattributed remainder unless it falls between
    two hooked tails and is absorbed by the later chained window;
    `meta.unhooked_modules` lists each unhooked module; and the envelope is
    `degraded: true` with
    `:unhooked` among `meta.degraded_reasons`. A zero-hooked run
    with a non-empty remainder still writes the degraded envelope.
  priority: must
  stability: evolving
- id: specled.coverage_capture.never_ran_not_inventoried
  statement: >-
    A `test_finished` whose `test.state` is `{:excluded, _}`,
    `{:skipped, _}`, or `{:invalid, _}` never reached `setup`, so a
    boundary row cannot exist for it: the formatter shall not inventory it,
    it shall not mark its module unhooked, and it shall not feed the
    `degraded_async?` fold. A fully hooked suite run under
    `--only`/`--exclude` or carrying `@tag :skip` tests stays undegraded,
    with no remediation notices. `{:failed, _}` tests ran (their `on_exit`
    executes and their window is real) and stay inventoried.
  priority: must
  stability: evolving
- id: specled.coverage_capture.unhooked_remediation_notice
  statement: >-
    For each module that had at least one unhooked test, the formatter shall
    print exactly one stderr remediation notice at `suite_finished` (never
    per test), naming the module, the unhooked test count, and the literal
    setup line `setup {SpecLedEx.Coverage, :per_test_boundary}` plus the
    `use SpecLedEx.Case` alternative for bare `ExUnit.Case` modules.
  priority: must
  stability: evolving
- id: specled.coverage_capture.path_identity
  statement: >-
    Formatter source identities shall be normalized to repository-root-relative
    paths before entering payload records, `meta.unattributed`, or
    `envelope.files`; absolute compile-time source paths shall never be
    persisted. The module-to-source map shall be derived once from the
    suite-start module scope and reused for both boundary payload and aggregate
    remainder compaction.
  priority: must
  stability: evolving
- id: specled.coverage_capture.unmapped_modules_meta
  statement: >-
    When a module contributes a boundary hit or unattributed run-total hit but
    the suite's module-to-source map cannot resolve that module to a
    repository-root-relative source path, `Formatter.flush/1` shall retain the
    omission explicitly as `meta.unmapped_modules`, a sorted unique module
    list. The module's lines shall not be fabricated under another file or
    silently folded into a reported file's percentage.
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
    - stub_fn was called once for the baseline (not again on test_finished)
    - the inventory row under P carries test_id, tags, and test_key — no per-test files/hits
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
    - "a baseline snapshot and a final suite snapshot where one line's count is unchanged and another's has strictly decreased"
  when:
    - the formatter diffs the two snapshots on suite_finished
  then:
    - "the unchanged line is not recorded as a hit (no placeholder)"
    - "the decreased line is counted as a `counters_externally_harvested` diagnostic, surfaced via stderr at `suite_finished`, and marks the run degraded — never recorded as a negative hit"
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
    - "a `--per-test` run where one captured test's tags carried `async: true`, or a zero-hooked run with a non-empty aggregate remainder"
  when:
    - "the formatter flushes on `suite_finished`"
  then:
    - "the written v2 envelope has `mode: :per_test` and `degraded: true`"
    - "when async contaminated, `:payload` is the v1-shaped record list"
    - "when zero-hooked with a non-empty remainder, empty `:payload` alone does not refuse the write; `:files` is non-empty"
  covers:
    - specled.coverage_capture.per_test_v2_envelope
- id: specled.coverage_capture.scenario.cumulative_parity_tripwire
  given:
    - "a child-BEAM fixture run once as plain `mix test --cover --export-coverage <a>` and once as `mix spec.cover.test --per-test --export-coverage <b>`"
  when:
    - "both exported `.coverdata` files are decoded via `:cover.import/1` + per-module `:cover.analyse/3` in a child BEAM — never by stopping or restarting the host BEAM's `:cover` server, which an enclosing `mix test --cover` run owns"
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
- id: specled.coverage_capture.scenario.spec_cover_test_per_test_freshness
  given:
    - "a per-test artifact path whose status/envelope state is exercised as missing, refused, stale-successful, and fresh-successful"
    - "the stale-successful case has both a successful sidecar and a decoded v2 envelope whose generated_at is older than the suite-start timestamp"
  when:
    - "`mix spec.cover.test --per-test` performs its post-suite freshness guard"
  then:
    - "only the fresh-successful artifact is accepted"
    - "the stale-successful artifact is rejected by the generated_at comparison rather than by the missing/refused/read-failure clauses"
    - "a red suite that does write an envelope newer than the pre-suite timestamp keeps its ordinary red-suite failure with no stale-artifact error"
  covers:
    - specled.coverage_capture.per_test_artifact_freshness
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
- id: specled.coverage_capture.scenario.boundary_hook_window
  given:
    - "the arming seam carries `boundary_table: tid` and a stub `snapshot_fn`"
    - "a test registers `setup {SpecLedEx.Coverage, :per_test_boundary}`"
  when:
    - "two tests run (one initial head, each tail at on_exit, with the first tail reused as the second head)"
  then:
    - "the boundary table holds rows keyed by `{module, name}` whose hits are the strict positive diffs of their chained windows"
    - "three whole-scope snapshot reads occur for two tests, and each on_exit closure needs only its test key"
  covers:
    - specled.coverage_capture.boundary_hook_sync
- id: specled.coverage_capture.scenario.boundary_noop_under_plain_mix_test
  given:
    - "`Application.get_env(:specled_ex, :spec_cover_run)` is unset, `true`, or carries an invalid/deleted `:boundary_table`"
    - "a module uses `SpecLedEx.Case` (or the setup line directly)"
  when:
    - "plain `mix test` runs the module"
  then:
    - "the setup is a pure no-op (no snapshot, no ETS write, no error)"
  covers:
    - specled.coverage_capture.boundary_noop_unarmed
- id: specled.coverage_capture.scenario.case_template_injects_setup
  given:
    - "the production `SpecLedEx.Case` template is loaded"
  when:
    - "an adopter writes `use SpecLedEx.Case`"
  then:
    - "the adopter module is an `ExUnit.Case` that receives forwarded options (`async: true`) and runs the injected `setup {SpecLedEx.Coverage, :per_test_boundary}` before the test body"
  covers:
    - specled.coverage_capture.case_template
- id: specled.coverage_capture.scenario.boundary_row_preferred_on_flush
  given:
    - "an inventoried test key with a boundary row containing the test's hit lines"
    - "a second inventoried test key with no boundary row"
  when:
    - "`Formatter.flush/1` runs on `suite_finished`"
  then:
    - "the hooked test's flushed record is derived exclusively from its boundary window"
    - "the unhooked test produces no per-test payload record; no lazy-capture fallback is fabricated"
    - "the envelope carries `meta: %{boundary: true}`"
  covers:
    - specled.coverage_capture.boundary_row_exclusive
- id: specled.coverage_capture.scenario.seeded_exclusive_attribution
  given:
    - "a child-BEAM fixture whose two tests (hooked via `SpecLedEx.Case`) call disjoint functions of a fixture module"
  when:
    - "`mix spec.cover.test --per-test --seed S` runs for each of three distinct explicit seeds"
  then:
    - "each run's records are non-empty, pairwise disjoint, and confined to each test's own function lines"
  covers:
    - specled.coverage_capture.per_test_exclusive_attribution
- id: specled.coverage_capture.scenario.envelope_meta_tolerant_read
  given:
    - "a v2 envelope written without a `:meta` key (pre-Stage-1 shape)"
    - "a formatter flush with a hit module absent from the suite-start file map"
    - "a v2 envelope whose `:meta` key holds a non-map term"
  when:
    - "`Store.read_v2/1` reads that path"
  then:
    - "the decoded envelope has `meta: %{}`"
    - "when flush consumes a boundary row, the written envelope carries `meta.boundary: true`"
    - "the unmapped hit module is retained in `meta.unmapped_modules`"
    - "an envelope stripped of `:meta` is accepted by `write_v2/2` and reads back with `meta: %{}`"
    - "an envelope whose present `:meta` is not a map reads back as `{:error, :invalid_artifact}`"
  covers:
    - specled.coverage_capture.envelope_meta
- id: specled.coverage_capture.scenario.write_v2_argument_error_contract
  given:
    - "a well-formed v2 envelope"
  when:
    - "`Store.write_v2/2` is called with that envelope carrying a non-map `:meta`, and again with a required field removed"
  then:
    - "each call raises `ArgumentError`, the exception the function documents — never `KeyError`"
  covers:
    - specled.coverage_capture.write_v2_argument_error_contract
- id: specled.coverage_capture.scenario.degraded_reasons_overlap
  given:
    - "an armed formatter whose run is degraded by BOTH an async-tagged test and an unhooked test"
  when:
    - "suite_finished flushes the envelope"
  then:
    - "meta.degraded_reasons contains both :async and :unhooked — the overlap is recorded, never collapsed to whichever meta key a consumer checks first"
    - "single-cause degrades record exactly their one cause; a legacy degraded envelope without the key reads back as [:unhooked] when unhooked-modules meta is present, [:async] otherwise"
  covers:
    - specled.coverage_capture.degraded_reasons
- id: specled.coverage_capture.scenario.never_ran_not_inventoried
  given:
    - "a fully hooked run whose test_finished stream includes an excluded, a skipped, and an invalid test alongside hooked tests that ran"
  when:
    - "suite_finished flushes the envelope"
  then:
    - "the never-ran tests are not inventoried: the envelope is not degraded, carries no meta.unhooked_modules, and prints no remediation notice"
    - "a {:failed, _} test ran and stays inventoried"
  covers:
    - specled.coverage_capture.never_ran_not_inventoried
- id: specled.coverage_capture.scenario.formatter_auditor_inventory_only
  given:
    - "an armed formatter with a stub snapshot_fn and no boundary rows"
    - "suite_started then two test_finished events"
  when:
    - "suite_finished runs"
  then:
    - "snapshot_fn was called exactly twice (baseline + final), never per test"
    - "payload is empty; inventory alone never fabricates per-test hits"
  covers:
    - specled.coverage_capture.formatter_auditor
- id: specled.coverage_capture.scenario.unhooked_degrade_partial_hook
  given:
    - "a child-BEAM fixture with one hooked module (SpecLedEx.Case) and one unhooked bare ExUnit.Case module"
  when:
    - "`mix spec.cover.test --per-test` runs on the fixture"
  then:
    - "exit code is 0"
    - "envelope is degraded: true with meta.unhooked_modules naming the unhooked module"
    - "the hooked test's payload row is present and exact within its disclosed chained window"
    - "stderr notice names the unhooked module and contains `setup {SpecLedEx.Coverage, :per_test_boundary}`"
  covers:
    - specled.coverage_capture.unhooked_degrade
    - specled.coverage_capture.unhooked_remediation_notice
- id: specled.coverage_capture.scenario.path_identity_and_unmapped_modules
  given:
    - "a formatter scope with one loadable module and one module whose source cannot resolve"
    - "boundary and run-total hits for both modules"
  when:
    - "`Formatter.flush/1` compacts the boundary payload and aggregate remainder through its suite-start file map"
  then:
    - "the loadable module's payload file is repository-root-relative"
    - "the unresolved module is named once in `meta.unmapped_modules` and its lines are not fabricated under the mapped file"
  covers:
    - specled.coverage_capture.path_identity
    - specled.coverage_capture.unmapped_modules_meta
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
    - specled.coverage_capture.per_test_artifact_freshness
    - specled.coverage_capture.cumulative_parity
    - specled.coverage_capture.per_test_exclusive_attribution
    - specled.coverage_capture.boundary_row_exclusive
    - specled.coverage_capture.boundary_hook_sync
    - specled.coverage_capture.case_template
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.aggregate_ingest
    - specled.coverage_capture.aggregate_empty_coverage
    - specled.coverage_capture.aggregate_unmapped_degraded
    - specled.coverage_capture.mfa_key_round_trip
    - specled.coverage_capture.mfa_lines_index
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.snapshot_runtime_mode
    - specled.coverage_capture.snapshot_diff_strictly_increased
    - specled.coverage_capture.snapshot_negative_delta_diagnostic
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.boundary_noop_unarmed
    - specled.coverage_capture.envelope_meta
    - specled.coverage_capture.write_v2_argument_error_contract
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.formatter_auditor
    - specled.coverage_capture.unhooked_degrade
    - specled.coverage_capture.unhooked_remediation_notice
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.degraded_reasons
    - specled.coverage_capture.never_ran_not_inventoried
- kind: tagged_tests
  execute: true
  covers:
    - specled.coverage_capture.path_identity
    - specled.coverage_capture.unmapped_modules_meta
```
