defmodule SpecLedEx.Coverage.Boundary do
  @moduledoc """
  Synchronous per-test coverage boundary engine.

  Takes one initial whole-scope snapshot, then a tail snapshot in each
  test's `on_exit` (awaited by `ExUnit.Runner.exec_on_exit/3` before the next
  test spawns). Each tail is cached in the boundary ETS table as the next
  test's head, so the `on_exit` closure retains only the test key.

  The capture cost is one O(modules × lines) initial snapshot plus one
  O(modules × lines) snapshot, one `Snapshot.diff/2`, and ETS operations per
  hooked test. No `module_info/1` calls occur on the boundary hot path.
  """

  alias SpecLedEx.Coverage.{Arming, Snapshot}

  @type test_key :: {module(), atom()}
  @type head_result :: :armed | :unarmed
  @type boundary_row :: %{
          hits: %{module() => [pos_integer()]},
          diagnostics: non_neg_integer()
        }

  @head_snapshot_key :__specled_boundary_head_snapshot__

  @doc """
  Head boundary: resolve arming and ensure the chained head snapshot exists.
  The first hooked test takes the run's initial snapshot; later tests reuse
  the prior test's tail. Returns `:unarmed` (no other work) when the seam is
  unset, `false`, or lacks a `:boundary_table`.
  """
  @spec head(map()) :: head_result()
  def head(_context) do
    case Arming.resolve(:boundary) do
      :disarmed ->
        :unarmed

      {:armed, config} ->
        try do
          case :ets.lookup(config.boundary_table, @head_snapshot_key) do
            [{@head_snapshot_key, _snapshot}] ->
              :armed

            [] ->
              modules = Arming.modules(config)
              snapshot = config.snapshot_fn.(modules)
              true = :ets.insert(config.boundary_table, {@head_snapshot_key, snapshot})
              :armed
          end
        rescue
          ArgumentError -> :unarmed
        end
    end
  end

  @doc """
  Tail boundary: take the tail snapshot, diff against the chained head,
  insert the boundary row, then retain that tail as the next test's head.
  No-ops when unarmed.
  """
  @spec tail(module(), atom()) :: :ok
  def tail(module, name) when is_atom(module) and is_atom(name) do
    case Arming.resolve(:boundary) do
      :disarmed ->
        :ok

      {:armed, config} ->
        try do
          case :ets.lookup(config.boundary_table, @head_snapshot_key) do
            [{@head_snapshot_key, head_snapshot}] ->
              modules = Arming.modules(config)
              tail_snapshot = config.snapshot_fn.(modules)
              {hits_by_module, diagnostics} = Snapshot.diff(head_snapshot, tail_snapshot)

              row = %{
                hits: hits_by_module,
                diagnostics: length(diagnostics)
              }

              true =
                :ets.insert(config.boundary_table, [
                  {{module, name}, row},
                  {@head_snapshot_key, tail_snapshot}
                ])

            [] ->
              :ok
          end
        rescue
          ArgumentError -> :ok
        end

        :ok
    end
  end
end
