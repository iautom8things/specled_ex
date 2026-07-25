defmodule SpecLedEx.Coverage.Formatter do
  @moduledoc """
  ExUnit formatter that audits per-test coverage capture under
  `mix spec.cover.test --per-test`.

  This module is the suite-lifecycle owner for the opt-in per-test lane; it is
  no longer the measurement engine. Exclusive per-test attribution comes from
  the synchronous boundary hook (`SpecLedEx.Coverage.per_test_boundary/1` /
  `use SpecLedEx.Case`) — head snapshot at setup, tail snapshot in `on_exit`,
  which `ExUnit.Runner` awaits via `exec_on_exit/3` before spawning the next
  test. Hooked tests' `[head, tail]` windows are therefore disjoint
  (**exact up to escaped processes**: a process a test spawns that outlives
  its tail snapshot can still increment shared counters after the window
  closes, landing in a later window or the unattributed remainder).

  ## Suite lifecycle (auditor)

  On `suite_started`, takes one baseline whole-scope module snapshot and
  memoizes the module → source-file map (each computed exactly once for the
  run). On each `test_finished`, records inventory only (`{key, test_id,
  tags, test_pid}`) — no per-test snapshot. On `suite_finished`:

    1. Takes one final whole-scope snapshot; run-total hits =
       `Snapshot.diff(baseline, final)`.
    2. Attributed hits = union of boundary-table rows (hooked tests).
    3. Unattributed remainder = run-total minus attributed (line-level set
       subtraction). Remainder lands in `meta.unattributed` as
       `[{file, sorted_lines}]` and contributes to `envelope.files` so
       file-level consumers still see the whole run.
    4. Per-test `:payload` carries only hooked tests' boundary-derived
       records.
    5. Audit: inventory keys vs boundary-reported keys, grouped by module.
       Unhooked modules are listed in `meta.unhooked_modules`; the envelope
       is `degraded: true` whenever any test is unhooked (plus the existing
       async / externally-harvested diagnostic conditions). One per-module
       stderr notice names the literal setup line to add.

  A run with zero hooked rows but a non-empty aggregate remainder still
  writes the degraded envelope. Only a genuinely empty run (no files at
  all) refuses via `Store.write_v2/2`'s empty-files gate.

  ## Disarmed By Default

  Registering this module in `:formatters` (e.g. a bare
  `ExUnit.start(formatters: [ExUnit.CLIFormatter, SpecLedEx.Coverage.Formatter])`
  in `test_helper.exs`) is not enough to activate it. `init/1` checks
  `Application.get_env(:specled_ex, :spec_cover_run)`; when that is unset or
  `false`, the formatter prints one notice to stderr and becomes a permanent
  no-op (`{:ok, :disabled}`, every event handled as `{:noreply, :disabled}`).
  Only `mix spec.cover.test --per-test` arms it, via
  `Application.put_env(:specled_ex, :spec_cover_run, ...)` before installing
  the formatter. Production arms with a keyword list that includes
  `boundary_table: tid` (public anonymous ETS table for boundary rows);
  tests may arm with `true` or a keyword override for DI seams.

  This closes an accidental smuggle path: ExUnit starts every formatter with
  `GenServer.start_link(handler, opts)` where `opts` is effectively the whole
  `:ex_unit` application environment (see `ExUnit.configuration/0`) — not
  anything this module's caller chose to pass. `init/1`'s own argument is
  therefore ignored entirely; it is not a trustworthy source of formatter
  config. Once armed, the real config comes only from the arming value
  itself:

    * `Application.put_env(:specled_ex, :spec_cover_run, true)` — production
      defaults (`snapshot_fn` dispatches to `Snapshot.take(Snapshot.runtime_mode(),
      modules)`). Prefer the keyword form with `:boundary_table` in real
      `--per-test` runs (the Mix task sets it).
    * `Application.put_env(:specled_ex, :spec_cover_run, snapshot_fn: ...,
      boundary_table: tid, ...)` — a keyword list is honored as an explicit
      config override, merged over the production defaults. Tests use this
      seam to inject a `snapshot_fn` stub
      (`([module()] -> %{module() => [{line, count}]})`); nothing outside the
      `:specled_ex` namespace can reach the formatter's config.

  ## Init Options

  None are read from `init/1`'s argument — see "Disarmed By Default" above.
  The resolved config carries:

    * `:snapshot_fn` — `([module()] -> %{module() => [{line, count}]})`;
      production default is `Snapshot.take(Snapshot.runtime_mode(), modules)`
      (see `SpecLedEx.Coverage.Snapshot` for the native/classic engines).
      Called at `suite_started` (baseline) and `suite_finished` (final) only —
      never per test.
    * `:modules_fn` — `(-> [module()])`; default
      `&SpecLedEx.Coverage.cover_modules_safe/0`. Computes the module scope
      snapshots are taken over; called once, at `suite_started`.
    * `:artifact_path` — destination for the on-suite-finish flush.
    * `:boundary_table` — public anonymous ETS table for boundary rows
      (armed by `mix spec.cover.test --per-test`).

  ## Test key / inventory

  Inventory rows are keyed by `test_pid` when the test struct's tags carry
  one (e.g. user setup that populates `@tag test_pid: ...`); otherwise the
  key falls back to `{module, name}`, which is also unique per test. Either
  form guarantees no collision under serialized execution. Boundary rows
  are always keyed by `{module, name}` (see `SpecLedEx.Coverage.Boundary`);
  flush matches inventory to boundary via that stable test key.

  The on-disk record's `test_pid` field is the same `tags[:test_pid]` when
  present; otherwise the formatter's own pid (a valid pid for the field
  type) is recorded. ExUnit does not expose the test's runtime pid inside
  `test.tags` — it lives in the test's `context`, not its tags — so a
  durable per-test pid in the artifact requires user opt-in via tags.
  """

  use GenServer

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.{Arming, Snapshot, Store}

  # `opts` here is not a caller's intent — ExUnit forwards its entire
  # application environment to every formatter GenServer it starts (see
  # `moduledoc`). It is ignored; config comes only from the arming seam.
  @impl GenServer
  def init(_opts) do
    case Arming.resolve(:formatter) do
      :disarmed ->
        IO.puts(:stderr, disarmed_notice())
        {:ok, :disabled}

      {:armed, arming} ->
        config =
          Coverage.init(
            snapshot_fn: arming.snapshot_fn,
            modules_fn: arming.modules_fn,
            artifact_path: arming.artifact_path
          )

        state = Coverage.install(config)
        {:ok, run_init(state)}
    end
  end

  # Per-run bookkeeping layered on top of the static config
  # `Coverage.install/1` resolves. `:modules` and `:file_map` are populated
  # once, at `suite_started`, and never recomputed per test. `:baseline` is
  # the suite_started snapshot; the formatter does not take per-test
  # snapshots (auditor demotion — Stage 2).
  defp run_init(state) do
    Map.merge(state, %{
      modules: nil,
      file_map: %{},
      baseline: %{},
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
      |> Map.put(:baseline, baseline)

    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, record_inventory(test, state)}
  end

  @impl GenServer
  def handle_cast({:suite_finished, _times}, state) do
    flush(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_event, state), do: {:noreply, state}

  # ExUnit emits `test_finished` for tests it never ran (excluded, skipped,
  # invalid setup_all). Those tests never reach `setup`, so a boundary row
  # cannot exist for them — inventorying them would mark correctly-wired
  # modules unhooked. `{:failed, _}` tests DID run (their on_exit executes)
  # and keep their real window, so they stay inventoried.
  defp record_inventory(%ExUnit.Test{state: {reason, _}}, state)
       when reason in [:excluded, :skipped, :invalid] do
    state
  end

  # Inventory only — no per-test snapshot. A `test_finished` arriving with no
  # prior `suite_started` resolves module scope lazily rather than crashing.
  defp record_inventory(%ExUnit.Test{} = test, %{modules: nil} = state) do
    modules = state.modules_fn.()

    record_inventory(test, %{
      state
      | modules: modules,
        file_map: build_file_map(modules),
        baseline: %{}
    })
  end

  defp record_inventory(%ExUnit.Test{} = test, state) do
    async? = Map.get(test.tags, :async, false) == true

    row = %{
      test_id: test_id(test),
      test_key: {test.module, test.name},
      module: test.module,
      tags: test.tags,
      test_pid: on_disk_pid(test.tags)
    }

    :ets.insert(state.table, {extract_key(test), row})

    %{state | degraded_async?: state.degraded_async? or async?}
  end

  # Builds the module -> source-file map once, up front, so flush never
  # re-derives it.
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
    modules = state.modules || state.modules_fn.()
    final = state.snapshot_fn.(modules)
    {run_total_hits, suite_diagnostics} = Snapshot.diff(state.baseline || %{}, final)

    boundary_index = load_boundary_index()
    inventory = :ets.tab2list(table)

    {boundary_inventory, unhooked_inventory} =
      Enum.split_with(inventory, fn {_key, row} ->
        Map.get(boundary_index, row.test_key) != nil
      end)

    boundary_rows =
      Enum.map(boundary_inventory, fn {_key, row} ->
        {row, Map.fetch!(boundary_index, row.test_key)}
      end)

    records =
      Enum.flat_map(boundary_rows, fn {row, boundary_row} ->
        records_for_inventory(row, boundary_row, state.file_map)
      end)

    boundary_diagnostics =
      Enum.sum(Enum.map(boundary_rows, fn {_row, boundary_row} -> boundary_row.diagnostics end))

    used_boundary? = boundary_rows != []

    unhooked_by_module =
      Enum.frequencies_by(unhooked_inventory, fn {_key, row} -> row.module end)

    attributed_hits = union_boundary_hits(boundary_index)
    unattributed_hits = subtract_hits(run_total_hits, attributed_hits)
    unattributed_files = compact_hits_to_files(unattributed_hits, state.file_map)

    total_diagnostics = state.diagnostic_count + boundary_diagnostics + length(suite_diagnostics)

    if total_diagnostics > 0 do
      IO.puts(:stderr, diagnostic_notice(total_diagnostics))
    end

    unhooked_modules =
      unhooked_by_module
      |> Map.keys()
      |> Enum.sort_by(&to_string/1)

    Enum.each(unhooked_modules, fn mod ->
      count = Map.fetch!(unhooked_by_module, mod)
      IO.puts(:stderr, unhooked_notice(mod, count))
    end)

    # Every cause that fired, in one place — consumers must never reconstruct
    # the cause by asking which meta key happens to be present. `:async` and
    # `:counters_harvested` invalidate the hooked windows; `:unhooked` merely
    # omits the unhooked tests' coverage from the payload.
    degraded_reasons =
      Enum.reject(
        [
          if(state.degraded_async?, do: :async),
          if(total_diagnostics > 0, do: :counters_harvested),
          if(unhooked_modules != [], do: :unhooked)
        ],
        &is_nil/1
      )

    degraded? = degraded_reasons != []

    payload_files = records |> Enum.map(& &1.file) |> Enum.uniq()
    remainder_file_paths = Enum.map(unattributed_files, fn {file, _lines} -> file end)

    files =
      (payload_files ++ remainder_file_paths)
      |> Enum.uniq()
      |> Enum.sort()

    meta =
      %{}
      |> maybe_put(:boundary, used_boundary?, true)
      |> maybe_put(:unhooked_modules, unhooked_modules != [], unhooked_modules)
      |> maybe_put(:unattributed, unattributed_files != [], unattributed_files)
      |> maybe_put(:degraded_reasons, degraded?, degraded_reasons)

    envelope =
      Store.build_envelope(%{
        mode: :per_test,
        source: path,
        files: files,
        mfas: [],
        payload: records,
        degraded: degraded?,
        meta: meta
      })

    case Store.write_v2(envelope, path) do
      :ok ->
        :ok

      {:error, :empty_files} ->
        IO.puts(:stderr, empty_run_notice())
    end
  end

  # Prefer a boundary-table row when present for a test's `{module, name}`
  # key. Unhooked inventory entries produce no payload records — their
  # coverage folds into the suite remainder via set subtraction.
  defp records_for_inventory(row, boundary_row, file_map) do
    boundary_row.hits
    |> compact_hits_to_files(file_map)
    |> Enum.map(fn {file, lines} ->
      %{
        test_id: row.test_id,
        file: file,
        lines_hit: lines,
        tags: row.tags,
        test_pid: row.test_pid
      }
    end)
  end

  defp load_boundary_index do
    case Arming.resolve(:boundary) do
      {:armed, config} -> Arming.boundary_index(config)
      :disarmed -> %{}
    end
  end

  defp union_boundary_hits(boundary_index) do
    Enum.reduce(boundary_index, %{}, fn {_key, row}, acc ->
      hits = Map.get(row, :hits, %{})

      Enum.reduce(hits, acc, fn {mod, lines}, acc2 ->
        Map.update(acc2, mod, MapSet.new(lines), fn set ->
          Enum.reduce(lines, set, &MapSet.put(&2, &1))
        end)
      end)
    end)
    |> Map.new(fn {mod, set} -> {mod, MapSet.to_list(set) |> Enum.sort()} end)
  end

  # Line-level set subtraction: run-total hits minus attributed hits.
  defp subtract_hits(run_total, attributed) when is_map(run_total) and is_map(attributed) do
    Enum.reduce(run_total, %{}, fn {mod, lines}, acc ->
      attr = MapSet.new(Map.get(attributed, mod, []))
      remaining = lines |> Enum.reject(&MapSet.member?(attr, &1)) |> Enum.sort()

      if remaining == [] do
        acc
      else
        Map.put(acc, mod, remaining)
      end
    end)
  end

  defp maybe_put(map, _key, false, _value), do: map
  defp maybe_put(map, key, true, value), do: Map.put(map, key, value)

  defp diagnostic_notice(count) do
    "[SpecLedEx.Coverage.Formatter] #{count} counters-externally-harvested " <>
      "diagnostic(s): a snapshot read a lower count than the previous boundary " <>
      "snapshot for the same line, meaning something other than this formatter " <>
      "drained the shared coverage counters mid-run. The artifact is marked " <>
      "degraded rather than treating the decrease as a real (negative) delta."
  end

  defp unhooked_notice(module, count) do
    tests = if count == 1, do: "1 test", else: "#{count} tests"

    "[SpecLedEx.Coverage.Formatter] #{tests} in #{inspect(module)} ran without the " <>
      "per-test boundary hook; their coverage was folded into the run's " <>
      "aggregate remainder and the artifact is marked degraded. Add to the case " <>
      "(or its case template): setup {SpecLedEx.Coverage, :per_test_boundary} " <>
      "— or use SpecLedEx.Case for bare ExUnit.Case modules."
  end

  defp empty_run_notice do
    "[SpecLedEx.Coverage.Formatter] no per-test coverage hits were captured " <>
      "this run; no artifact was written."
  end
end
