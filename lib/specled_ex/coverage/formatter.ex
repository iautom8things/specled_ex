defmodule SpecLedEx.Coverage.Formatter do
  @moduledoc """
  ExUnit formatter that captures per-test cover snapshots.

  On `suite_started`, takes a baseline module snapshot via
  `SpecLedEx.Coverage.Snapshot` (native or classic, per
  `Snapshot.runtime_mode/0`) and memoizes a module → source-file map for
  the run's module scope (each computed exactly once for the whole run —
  no per-test/per-flush `module_info/1` storm). On `test_finished`, takes
  a new snapshot over the same scope, diffs it against the previous
  boundary snapshot (the baseline for test 1, the prior test's snapshot
  thereafter) via `Snapshot.diff/2`, compacts the resulting hits to
  `[{file, sorted_lines}]` at cast time, and writes that compacted row
  into an anonymous ETS table keyed by `test_pid`. On `suite_finished`,
  derives per-test v1-shaped records (`%{test_id, file, lines_hit, tags,
  test_pid}`) from the ETS state and writes them, wrapped in a v2
  `:per_test` envelope, via `SpecLedEx.Coverage.Store.write_v2/2` to
  `.spec/_coverage/per_test.coverdata` (overridable via the
  `:artifact_path` init option). No raw `:cover`/native snapshot blob is
  ever retained in the ETS table — only the compacted `{file, lines}`
  pairs.

  The envelope is marked `degraded: true` when either of two things is
  observed during the run: a test's tags carried `async: true` (ExUnit
  sets this per test from the enclosing module's real async status,
  independent of `--per-test`'s forced `ExUnit.configure(async: false)` —
  see `specled.decision.serialized_per_test_coverage`; a module that
  declares `async: true` genuinely runs concurrently regardless), or
  `Snapshot.diff/2` reported a "counters externally harvested" diagnostic
  (something other than this formatter drained the shared counters
  between two of its own snapshots). Either condition means per-test
  attribution for the affected window cannot be trusted.

  ## Disarmed By Default

  Registering this module in `:formatters` (e.g. a bare
  `ExUnit.start(formatters: [ExUnit.CLIFormatter, SpecLedEx.Coverage.Formatter])`
  in `test_helper.exs`) is not enough to activate it. `init/1` checks
  `Application.get_env(:specled_ex, :spec_cover_run)`; when that is unset or
  `false`, the formatter prints one notice to stderr and becomes a permanent
  no-op (`{:ok, :disabled}`, every event handled as `{:noreply, :disabled}`).
  Only `mix spec.cover.test --per-test` arms it, via
  `Application.put_env(:specled_ex, :spec_cover_run, true)` before installing
  the formatter.

  This closes an accidental smuggle path: ExUnit starts every formatter with
  `GenServer.start_link(handler, opts)` where `opts` is effectively the whole
  `:ex_unit` application environment (see `ExUnit.configuration/0`) — not
  anything this module's caller chose to pass. `init/1`'s own argument is
  therefore ignored entirely; it is not a trustworthy source of formatter
  config. Once armed, the real config comes only from the arming value
  itself:

    * `Application.put_env(:specled_ex, :spec_cover_run, true)` — production
      config (`snapshot_fn` dispatches to `Snapshot.take(Snapshot.runtime_mode(),
      modules)`), as `mix spec.cover.test --per-test` sets it.
    * `Application.put_env(:specled_ex, :spec_cover_run, snapshot_fn: ..., ...)`
      — a keyword list is honored as an explicit config override, merged over
      the production defaults. Tests use this seam to inject a `snapshot_fn`
      stub (`([module()] -> %{module() => [{line, count}]})`); nothing
      outside the `:specled_ex` namespace can reach the formatter's config.

  ## Init Options

  None are read from `init/1`'s argument — see "Disarmed By Default" above.
  The resolved config carries:

    * `:snapshot_fn` — `([module()] -> %{module() => [{line, count}]})`;
      production default is `Snapshot.take(Snapshot.runtime_mode(), modules)`
      (see `SpecLedEx.Coverage.Snapshot` for the native/classic engines).
    * `:modules_fn` — `(-> [module()])`; default
      `&SpecLedEx.Coverage.cover_modules_safe/0`. Computes the module scope
      snapshots are taken over; called once, at `suite_started`.
    * `:artifact_path` — destination for the on-suite-finish flush.

  ## Test PID Capture

  The ETS row is keyed by `test_pid` when the test struct's tags carry one
  (e.g. user setup that populates `@tag test_pid: ...`); otherwise the key
  falls back to `{module, name}`, which is also unique per test. Either form
  guarantees no collision under serialized execution.

  The on-disk record's `test_pid` field is the same `tags[:test_pid]` when
  present; otherwise the formatter's own pid (a valid pid for the field
  type) is recorded. ExUnit does not expose the test's runtime pid inside
  `test.tags` — it lives in the test's `context`, not its tags — so a
  durable per-test attribution requires user opt-in via tags.
  """

  use GenServer

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.{Snapshot, Store}

  @arming_app :specled_ex
  @arming_key :spec_cover_run

  # `opts` here is not a caller's intent — ExUnit forwards its entire
  # application environment to every formatter GenServer it starts (see
  # `moduledoc`). It is ignored; config comes only from the arming seam.
  @impl GenServer
  def init(_opts) do
    case armed() do
      :disarmed ->
        IO.puts(:stderr, disarmed_notice())
        {:ok, :disabled}

      seam_opts ->
        config = Coverage.init(Keyword.merge(production_defaults(), seam_opts))
        state = Coverage.install(config)
        {:ok, run_init(state)}
    end
  end

  defp armed do
    case Application.get_env(@arming_app, @arming_key) do
      opts when is_list(opts) -> opts
      true -> []
      _disarmed -> :disarmed
    end
  end

  defp production_defaults do
    [snapshot_fn: &default_snapshot_fn/1]
  end

  defp default_snapshot_fn(modules), do: Snapshot.take(Snapshot.runtime_mode(), modules)

  # Per-run bookkeeping layered on top of the static config
  # `Coverage.install/1` resolves. `:modules` and `:file_map` are populated
  # once, at `suite_started` (see `handle_cast/2` below), and never
  # recomputed per test.
  defp run_init(state) do
    Map.merge(state, %{
      modules: nil,
      file_map: %{},
      last_snapshot: %{},
      diagnostic_count: 0,
      degraded_async?: false
    })
  end

  defp disarmed_notice do
    "[SpecLedEx.Coverage.Formatter] disabled: per-test coverage capture requires " <>
      "`mix spec.cover.test --per-test` (it arms via " <>
      "Application.put_env(:specled_ex, :spec_cover_run, true)). Wiring this " <>
      "formatter directly into ExUnit.start/1 without that task is a no-op."
  end

  @impl GenServer
  def handle_cast(_event, :disabled), do: {:noreply, :disabled}

  @impl GenServer
  def handle_cast({:suite_started, _opts}, state) do
    modules = state.modules_fn.()
    baseline = state.snapshot_fn.(modules)

    state =
      state
      |> Map.put(:modules, modules)
      |> Map.put(:file_map, build_file_map(modules))
      |> Map.put(:last_snapshot, baseline)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, record_test(test, state)}
  end

  @impl GenServer
  def handle_cast({:suite_finished, _times}, state) do
    flush(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_event, state), do: {:noreply, state}

  # A `test_finished` event arriving with no prior `suite_started` (should
  # not happen under real ExUnit, but is a cheap safety net) resolves
  # modules/baseline lazily rather than crashing the formatter.
  defp record_test(%ExUnit.Test{} = test, %{modules: nil} = state) do
    record_test(test, %{
      state
      | modules: state.modules_fn.(),
        file_map: build_file_map(state.modules_fn.()),
        last_snapshot: %{}
    })
  end

  defp record_test(%ExUnit.Test{} = test, state) do
    current = state.snapshot_fn.(state.modules)
    {hits_by_module, diagnostics} = Snapshot.diff(state.last_snapshot, current)

    files = compact_hits_to_files(hits_by_module, state.file_map)
    async? = Map.get(test.tags, :async, false) == true

    row = %{
      test_id: test_id(test),
      tags: test.tags,
      test_pid: on_disk_pid(test.tags),
      files: files
    }

    :ets.insert(state.table, {extract_key(test), row})

    %{
      state
      | last_snapshot: current,
        diagnostic_count: state.diagnostic_count + length(diagnostics),
        degraded_async?: state.degraded_async? or async?
    }
  end

  # Builds the module -> source-file map once, up front, so per-test
  # attribution never re-derives it.
  defp build_file_map(modules) do
    Map.new(modules, fn mod -> {mod, source_file(mod)} end)
  end

  # Compacts `%{module => [line]}` hits into `[{file, sorted_lines}]`,
  # merging lines from different modules that map to the same file and
  # dropping modules this run couldn't attribute to a source file.
  defp compact_hits_to_files(hits_by_module, file_map) do
    hits_by_module
    |> Enum.reduce(%{}, fn {mod, lines}, acc ->
      case Map.get(file_map, mod) do
        nil -> acc
        file -> Map.update(acc, file, lines, &(&1 ++ lines))
      end
    end)
    |> Enum.map(fn {file, lines} -> {file, lines |> Enum.uniq() |> Enum.sort()} end)
    |> Enum.sort()
  end

  defp extract_key(%ExUnit.Test{tags: %{test_pid: pid}}) when is_pid(pid), do: pid
  defp extract_key(%ExUnit.Test{module: mod, name: name}), do: {mod, name}

  defp test_id(%ExUnit.Test{module: mod, name: name}), do: "#{inspect(mod)}.#{name}"

  defp on_disk_pid(%{test_pid: pid}) when is_pid(pid), do: pid
  defp on_disk_pid(_), do: self()

  defp source_file(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        case module.module_info(:compile)[:source] do
          source when is_list(source) -> List.to_string(source)
          source when is_binary(source) -> source
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp flush(%{table: table, artifact_path: path} = state) do
    records =
      table
      |> :ets.tab2list()
      |> Enum.flat_map(&records_for_row/1)

    if state.diagnostic_count > 0 do
      IO.puts(:stderr, diagnostic_notice(state.diagnostic_count))
    end

    degraded? = state.degraded_async? or state.diagnostic_count > 0

    envelope =
      Store.build_envelope(%{
        mode: :per_test,
        source: path,
        files: records |> Enum.map(& &1.file) |> Enum.uniq() |> Enum.sort(),
        mfas: [],
        payload: records,
        degraded: degraded?
      })

    case Store.write_v2(envelope, path) do
      :ok ->
        :ok

      {:error, :empty_files} ->
        IO.puts(:stderr, empty_run_notice())
    end
  end

  defp records_for_row({_key, %{files: files} = row}) do
    Enum.map(files, fn {file, lines} ->
      %{
        test_id: row.test_id,
        file: file,
        lines_hit: lines,
        tags: row.tags,
        test_pid: row.test_pid
      }
    end)
  end

  defp diagnostic_notice(count) do
    "[SpecLedEx.Coverage.Formatter] #{count} counters-externally-harvested " <>
      "diagnostic(s): a snapshot read a lower count than the previous boundary " <>
      "snapshot for the same line, meaning something other than this formatter " <>
      "drained the shared coverage counters mid-run. The artifact is marked " <>
      "degraded rather than treating the decrease as a real (negative) delta."
  end

  defp empty_run_notice do
    "[SpecLedEx.Coverage.Formatter] no per-test coverage hits were captured " <>
      "this run; no artifact was written."
  end
end
