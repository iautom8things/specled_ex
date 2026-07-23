defmodule SpecLedEx.Coverage.Formatter do
  @moduledoc """
  ExUnit formatter that captures per-test cover snapshots.

  On `test_finished`, calls the injected `snapshot_fn` exactly once and writes
  `{snapshot, tags, test_id}` into an anonymous ETS table keyed by `test_pid`.
  On `suite_finished`, derives per-(test, file) records from the ETS state and
  writes them via `SpecLedEx.Coverage.Store.write/2` to
  `.spec/_coverage/per_test.coverdata` (overridable via the `:artifact_path`
  init option).

  ## Disarmed By Default

  Registering this module in `:formatters` (e.g. a bare
  `ExUnit.start(formatters: [ExUnit.CLIFormatter, SpecLedEx.Coverage.Formatter])`
  in `test_helper.exs`) is not enough to activate it. `init/1` checks
  `Application.get_env(:specled_ex, :spec_cover_run)`; when that is unset or
  `false`, the formatter prints one notice to stderr and becomes a permanent
  no-op (`{:ok, :disabled}`, every event handled as `{:noreply, :disabled}`).
  Only `mix spec.cover.test` arms it, via
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
      config (`:cover.analyse(target, :coverage, :line)`, `snapshot_target:
      :_`), as `mix spec.cover.test` sets it.
    * `Application.put_env(:specled_ex, :spec_cover_run, snapshot_fn: ..., ...)`
      — a keyword list is honored as an explicit config override, merged over
      the production defaults. Tests use this seam to inject a `snapshot_fn`
      stub; nothing outside the `:specled_ex` namespace can reach the
      formatter's config.

  ## Init Options

  None are read from `init/1`'s argument — see "Disarmed By Default" above.
  The resolved config carries:

    * `:snapshot_fn` — `(target -> snapshot)`; production default calls
      `:cover.analyse(target, :coverage, :line)` — explicit line-level
      granularity. The bare arity-1 `:cover.analyse/1` defaults to
      *function*-level granularity, which is what the deleted fabrication
      clause used to paper over by stamping every function-level entry as
      line 0; this formatter never calls it.
    * `:modules_fn` — `(-> [module()])`; default
      `&SpecLedEx.Coverage.cover_modules_safe/0`. Computes the cover module
      set passed to `snapshot_fn` (when `:snapshot_target` is left at its
      default `:_`, the modules list is what gets passed).
    * `:snapshot_target` — what to pass to `snapshot_fn`. When `:modules`,
      the result of `modules_fn.()` is passed; otherwise the literal value
      is passed (production default `:_`, matching `:cover.analyse/1`'s "all
      modules" placeholder).
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
  alias SpecLedEx.Coverage.Store

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
        {:ok, state}
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
    [snapshot_fn: &default_snapshot_fn/1, snapshot_target: :_]
  end

  defp default_snapshot_fn(target), do: apply(:cover, :analyse, [target, :coverage, :line])

  defp disarmed_notice do
    "[SpecLedEx.Coverage.Formatter] disabled: per-test coverage capture requires " <>
      "`mix spec.cover.test` (it arms via " <>
      "Application.put_env(:specled_ex, :spec_cover_run, true)). Wiring this " <>
      "formatter directly into ExUnit.start/1 without that task is a no-op."
  end

  @impl GenServer
  def handle_cast(_event, :disabled), do: {:noreply, :disabled}

  @impl GenServer
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    record_test(test, state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast({:suite_finished, _times}, state) do
    flush(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_cast(_event, state), do: {:noreply, state}

  defp record_test(%ExUnit.Test{} = test, state) do
    target = snapshot_target(state)
    snapshot = state.snapshot_fn.(target)
    record = {snapshot, test.tags, test_id(test)}
    :ets.insert(state.table, {extract_key(test), record})
  end

  defp snapshot_target(%{snapshot_target: :modules, modules_fn: mods}), do: mods.()
  defp snapshot_target(%{snapshot_target: target}), do: target

  defp extract_key(%ExUnit.Test{tags: %{test_pid: pid}}) when is_pid(pid), do: pid
  defp extract_key(%ExUnit.Test{module: mod, name: name}), do: {mod, name}

  defp test_id(%ExUnit.Test{module: mod, name: name}), do: "#{inspect(mod)}.#{name}"

  defp flush(%{table: table, artifact_path: path}) do
    {record_lists, error_counts} =
      table
      |> :ets.tab2list()
      |> Enum.map(&records_for_test/1)
      |> Enum.unzip()

    decode_errors = Enum.sum(error_counts)

    if decode_errors > 0 do
      IO.puts(:stderr, decode_error_notice(decode_errors))
    end

    Store.write(List.flatten(record_lists), path)
  end

  defp decode_error_notice(count) do
    "[SpecLedEx.Coverage.Formatter] #{count} snapshot decode error(s): unrecognized or " <>
      "function-level (non-line) :cover snapshot entries were skipped, never fabricated " <>
      "into records."
  end

  # Returns `{records, decode_error_count}` for one test's accumulated
  # snapshot. A snapshot that decodes to no line-level entries at all (e.g.
  # `{:result, [], []}` — genuinely nothing covered) yields zero records: no
  # placeholder row is fabricated for it.
  defp records_for_test({_key, {snapshot, tags, test_id}}) do
    pid = on_disk_pid(tags)
    base = %{test_id: test_id, tags: tags, test_pid: pid}
    {per_file, decode_errors} = group_by_file(snapshot)

    records =
      Enum.map(per_file, fn {file, lines} ->
        Map.merge(base, %{file: file, lines_hit: lines})
      end)

    {records, decode_errors}
  end

  defp on_disk_pid(%{test_pid: pid}) when is_pid(pid), do: pid
  defp on_disk_pid(_), do: self()

  defp group_by_file({:result, ok_results, _failed}) when is_list(ok_results) do
    {file_lines, decode_errors} =
      Enum.reduce(ok_results, {[], 0}, fn entry, {acc, errors} ->
        case snapshot_entry_to_file_line(entry) do
          {:ok, file_line} -> {[file_line | acc], errors}
          :skip -> {acc, errors}
          :decode_error -> {acc, errors + 1}
        end
      end)

    per_file =
      file_lines
      |> Enum.reverse()
      |> Enum.group_by(fn {file, _line} -> file end, fn {_file, line} -> line end)
      |> Enum.map(fn {file, lines} -> {file, lines |> Enum.uniq() |> Enum.sort()} end)

    {per_file, decode_errors}
  end

  # Any snapshot shape besides `{:result, ok_results, failed}` is unrecognized
  # (e.g. `{:error, :not_cover_compiled}`, a stub returning garbage). It is
  # counted as a decode error and surfaced, never laundered into `[]` as if
  # it meant "nothing covered".
  defp group_by_file(_unrecognized_snapshot), do: {[], 1}

  # Line-level entry: the only shape that yields a real record.
  defp snapshot_entry_to_file_line({{module, line}, _calls})
       when is_atom(module) and is_integer(line) do
    case source_file(module) do
      nil -> :skip
      file -> {:ok, {file, line}}
    end
  end

  # Function-level (MFA) entry: `:cover.analyse/1` in `:calls`/`:function`
  # mode returns these instead of line-level tuples. There is no line number
  # to attribute, so this is never turned into a fabricated `{file, 0}`
  # record — it is counted as a decode error instead. This also means a
  # never-executed function (call count 0) never appears as a fake line hit.
  defp snapshot_entry_to_file_line({{module, _fun, _arity}, _cov})
       when is_atom(module) do
    :decode_error
  end

  defp snapshot_entry_to_file_line(_unrecognized_entry), do: :decode_error

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
end
