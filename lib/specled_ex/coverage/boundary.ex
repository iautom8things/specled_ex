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

  alias SpecLedEx.Coverage.{Arming, Snapshot}

  @type test_key :: {module(), atom()}
  @type head_result :: Snapshot.module_snapshot() | :unarmed
  @type boundary_row :: %{
          hits: %{module() => [pos_integer()]},
          diagnostics: non_neg_integer()
        }

  @doc """
  Head boundary: resolve arming, cache module scope once per run, take a
  snapshot. Returns `:unarmed` (no other work) when the seam is unset,
  `false`, or lacks a `:boundary_table`.
  """
  @spec head(map()) :: head_result()
  def head(_context) do
    case Arming.resolve(:boundary) do
      :disarmed ->
        :unarmed

      {:armed, config} ->
        modules = Arming.modules(config)
        config.snapshot_fn.(modules)
    end
  end

  @doc """
  Tail boundary: take the tail snapshot, diff against `head_snapshot`, insert
  `{test_key, row}` into the boundary table. No-ops when unarmed.
  """
  @spec tail(test_key(), Snapshot.module_snapshot()) :: :ok
  def tail(test_key, head_snapshot) when is_tuple(test_key) and is_map(head_snapshot) do
    case Arming.resolve(:boundary) do
      :disarmed ->
        :ok

      {:armed, config} ->
        modules = Arming.modules(config)
        tail_snapshot = config.snapshot_fn.(modules)
        {hits_by_module, diagnostics} = Snapshot.diff(head_snapshot, tail_snapshot)

        row = %{
          hits: hits_by_module,
          diagnostics: length(diagnostics)
        }

        true = :ets.insert(config.boundary_table, {test_key, row})

        :ok
    end
  end
end
