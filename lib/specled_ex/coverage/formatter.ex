defmodule SpecLedEx.Coverage.Formatter do
  @moduledoc """
  ExUnit formatter that captures per-test cover snapshots.

  On `test_finished`, calls the injected `snapshot_fn` exactly once and writes
  `{snapshot, tags, test_id}` into an anonymous ETS table keyed by `test_pid`.
  On `suite_finished`, derives per-(test, file) records from the ETS state and
  writes them via `SpecLedEx.Coverage.Store.write/2` to
  `.spec/_coverage/per_test.coverdata` (overridable via the `:artifact_path`
  init option).

  ## Init Options

    * `:snapshot_fn` — `(target -> snapshot)`; default `&:cover.analyse/1`.
      The formatter never calls `:cover.analyse/1` directly. Tests inject a
      stub.
    * `:modules_fn` — `(-> [module()])`; default
      `&SpecLedEx.Coverage.cover_modules_safe/0`. Computes the cover module
      set passed to `snapshot_fn` (when `:snapshot_target` is left at its
      default `:_`, the modules list is what gets passed).
    * `:snapshot_target` — what to pass to `snapshot_fn`. When `:modules`,
      the result of `modules_fn.()` is passed; otherwise the literal value
      is passed (default `:_`, matching `:cover.analyse/1`'s "all modules"
      placeholder).
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

  @impl GenServer
  def init(opts) do
    config = Coverage.init(opts)
    state = Coverage.install(config)
    {:ok, state}
  end

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
    records =
      table
      |> :ets.tab2list()
      |> Enum.flat_map(&records_for_test/1)

    Store.write(records, path)
  end

  defp records_for_test({_key, {snapshot, tags, test_id}}) do
    pid = on_disk_pid(tags)
    base = %{test_id: test_id, tags: tags, test_pid: pid}
    per_file = group_by_file(snapshot)

    cond do
      per_file != [] ->
        Enum.map(per_file, fn {file, lines} ->
          Map.merge(base, %{file: file, lines_hit: lines})
        end)

      true ->
        [Map.merge(base, %{file: Map.get(tags, :file, ""), lines_hit: []})]
    end
  end

  defp on_disk_pid(%{test_pid: pid}) when is_pid(pid), do: pid
  defp on_disk_pid(_), do: self()

  defp group_by_file({:result, ok_results, _failed}) when is_list(ok_results) do
    ok_results
    |> Enum.flat_map(&snapshot_entry_to_file_line/1)
    |> Enum.group_by(fn {file, _line} -> file end, fn {_file, line} -> line end)
    |> Enum.map(fn {file, lines} -> {file, lines |> Enum.uniq() |> Enum.sort()} end)
  end

  defp group_by_file(_), do: []

  defp snapshot_entry_to_file_line({{module, line}, _calls})
       when is_atom(module) and is_integer(line) do
    case source_file(module) do
      nil -> []
      file -> [{file, line}]
    end
  end

  defp snapshot_entry_to_file_line({{module, _fun, _arity}, _cov})
       when is_atom(module) do
    case source_file(module) do
      nil -> []
      file -> [{file, 0}]
    end
  end

  defp snapshot_entry_to_file_line(_), do: []

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
