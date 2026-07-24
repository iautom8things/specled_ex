defmodule SpecLedEx.Coverage.Boundary do
  @moduledoc """
  Synchronous per-test coverage boundary engine.

  Takes a head snapshot at test setup and a tail snapshot in `on_exit`
  (awaited by `ExUnit.Runner.exec_on_exit/3` before the next test spawns),
  then diffs the window and inserts the result into a public anonymous
  ETS table armed via the `:specled_ex, :spec_cover_run` seam.

  Hot path is two snapshot reads + one `Snapshot.diff/2` + one ETS insert —
  no `module_info/1` calls, and the head snapshot lives only in the
  `on_exit` closure (never retained outside it).
  """

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.Snapshot

  @arming_app :specled_ex
  @arming_key :spec_cover_run

  # Reserved key in the boundary table for the once-per-run modules cache.
  # Atom chosen to never collide with `{module, test_name}` test keys.
  @modules_key :__specled_boundary_modules__

  @type test_key :: {module(), atom()}
  @type head_result :: Snapshot.module_snapshot() | :unarmed
  @type boundary_row :: %{
          hits: %{module() => [pos_integer()]},
          diagnostics: non_neg_integer(),
          tags: map()
        }

  @doc """
  Head boundary: resolve arming, cache module scope once per run, take a
  snapshot. Returns `:unarmed` (no other work) when the seam is unset,
  `false`, or lacks a `:boundary_table`.
  """
  @spec head(map()) :: head_result()
  def head(_context) do
    case resolve_config() do
      :unarmed ->
        :unarmed

      config ->
        modules = modules_for(config)
        config.snapshot_fn.(modules)
    end
  end

  @doc """
  Tail boundary: take the tail snapshot, diff against `head_snapshot`, insert
  `{test_key, row}` into the boundary table. No-ops when unarmed.
  """
  @spec tail(test_key(), Snapshot.module_snapshot(), map()) :: :ok
  def tail(test_key, head_snapshot, tags \\ %{})

  def tail(test_key, head_snapshot, tags)
      when is_tuple(test_key) and is_map(head_snapshot) and is_map(tags) do
    case resolve_config() do
      :unarmed ->
        :ok

      config ->
        # The table is owned by the Mix task process in production (lives for
        # the whole suite). In unit tests the table may already be gone if the
        # owner process exited before ExUnit drains on_exit — treat that as a
        # no-op rather than raising out of the test runner.
        if table_alive?(config.boundary_table) do
          modules = modules_for(config)
          tail_snapshot = config.snapshot_fn.(modules)
          {hits_by_module, diagnostics} = Snapshot.diff(head_snapshot, tail_snapshot)

          row = %{
            hits: hits_by_module,
            diagnostics: length(diagnostics),
            tags: tags
          }

          true = :ets.insert(config.boundary_table, {test_key, row})
        end

        :ok
    end
  end

  @doc false
  @spec modules_cache_key() :: atom()
  def modules_cache_key, do: @modules_key

  defp resolve_config do
    case Application.get_env(@arming_app, @arming_key) do
      opts when is_list(opts) ->
        case Keyword.get(opts, :boundary_table) do
          nil ->
            :unarmed

          tid ->
            %{
              boundary_table: tid,
              snapshot_fn: Keyword.get(opts, :snapshot_fn, &default_snapshot_fn/1),
              modules_fn: Keyword.get(opts, :modules_fn, &Coverage.cover_modules_safe/0)
            }
        end

      _disarmed ->
        :unarmed
    end
  end

  defp modules_for(%{boundary_table: tid, modules_fn: modules_fn}) do
    case :ets.lookup(tid, @modules_key) do
      [{@modules_key, modules}] ->
        modules

      [] ->
        modules = modules_fn.()
        true = :ets.insert(tid, {@modules_key, modules})
        modules
    end
  end

  defp table_alive?(tid) do
    :ets.info(tid) != :undefined
  rescue
    ArgumentError -> false
  end

  defp default_snapshot_fn(modules), do: Snapshot.take(Snapshot.runtime_mode(), modules)
end
