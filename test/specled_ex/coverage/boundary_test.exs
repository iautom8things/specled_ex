defmodule SpecLedEx.Coverage.BoundaryTest do
  # Shares Application env arming seam with other coverage tests — must not race.
  use ExUnit.Case, async: false

  @moduletag spec: [
               "specled.coverage_capture.boundary_hook_sync",
               "specled.coverage_capture.boundary_noop_unarmed"
             ]

  alias SpecLedEx.Coverage.{Arming, Boundary}

  setup do
    on_exit(fn -> Application.delete_env(:specled_ex, :spec_cover_run) end)
    :ok
  end

  defp arm(opts) when is_list(opts) do
    Application.put_env(:specled_ex, :spec_cover_run, opts)
  end

  defp new_table do
    tid = :ets.new(:anon, [:public, :set])
    on_exit(fn -> if :ets.info(tid) != :undefined, do: :ets.delete(tid) end)
    tid
  end

  describe "head/1 — arming gate" do
    test "returns :unarmed when the seam is unset" do
      assert Boundary.head(%{module: M, test: :t}) == :unarmed
    end

    test "returns :unarmed when the seam is true (no boundary_table)" do
      Application.put_env(:specled_ex, :spec_cover_run, true)
      assert Boundary.head(%{module: M, test: :t}) == :unarmed
    end

    test "returns :unarmed when keyword seam lacks :boundary_table" do
      arm(snapshot_fn: fn _ -> %{} end)
      assert Boundary.head(%{module: M, test: :t}) == :unarmed
    end

    test "shared resolver requires a live ETS table for boundary arming" do
      snapshot_fn = fn _ -> flunk("snapshot must not run for an invalid table") end

      arm(boundary_table: make_ref(), snapshot_fn: snapshot_fn)
      assert Arming.resolve(:boundary) == :disarmed
      assert Boundary.head(%{}) == :unarmed

      tid = new_table()
      :ets.delete(tid)
      arm(boundary_table: tid, snapshot_fn: snapshot_fn)
      assert Arming.resolve(:boundary) == :disarmed
      assert Boundary.head(%{}) == :unarmed
    end

    test "shared resolver keeps true armed for formatter and disarmed for boundary" do
      Application.put_env(:specled_ex, :spec_cover_run, true)

      assert {:armed, config} = Arming.resolve(:formatter)
      assert is_function(config.snapshot_fn, 1)
      assert is_function(config.modules_fn, 0)
      assert config.artifact_path == ".spec/_coverage/per_test.coverdata"
      assert Arming.resolve(:boundary) == :disarmed
      refute function_exported?(Boundary, :modules_cache_key, 0)
    end
  end

  describe "head/1 + tail/2 - window diff semantics" do
    test "inserts hits for lines that strictly increased in the window" do
      tid = new_table()

      snapshots = [
        %{Mod => [{10, 0}, {20, 0}]},
        %{Mod => [{10, 2}, {20, 0}]}
      ]

      agent = start_supervised!({Agent, fn -> snapshots end})

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(
        boundary_table: tid,
        snapshot_fn: snapshot_fn,
        modules_fn: fn -> [Mod] end
      )

      head = Boundary.head(%{module: SampleTest, test: :"test path_a"})
      assert head == :armed

      assert :ok = Boundary.tail(SampleTest, :"test path_a")

      assert [{_key, row}] =
               :ets.lookup(tid, {SampleTest, :"test path_a"})

      assert row.hits == %{Mod => [10]}
      assert row.diagnostics == 0
      refute Map.has_key?(row, :tags)
    end

    test "caches modules_fn result once under the reserved key" do
      tid = new_table()
      parent = self()

      arm(
        boundary_table: tid,
        snapshot_fn: fn modules ->
          send(parent, {:snapshot_modules, modules})
          %{}
        end,
        modules_fn: fn ->
          send(parent, :modules_called)
          [ModA, ModB]
        end
      )

      _ = Boundary.head(%{})
      _ = Boundary.head(%{})
      assert_received :modules_called
      refute_received :modules_called
      assert_received {:snapshot_modules, [ModA, ModB]}
      refute_received {:snapshot_modules, [ModA, ModB]}

      assert Enum.any?(:ets.tab2list(tid), fn
               {key, [ModA, ModB]} when is_atom(key) -> true
               _ -> false
             end)
    end

    test "passes diagnostics count through on negative deltas" do
      tid = new_table()

      {:ok, agent} =
        Agent.start_link(fn -> [%{Mod => [{1, 5}]}, %{Mod => [{1, 2}]}] end)

      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      snapshot_fn = fn _ ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(boundary_table: tid, snapshot_fn: snapshot_fn, modules_fn: fn -> [Mod] end)

      assert :armed = Boundary.head(%{})
      assert :ok = Boundary.tail(T, :t)

      assert [{_, row}] = :ets.lookup(tid, {T, :t})
      assert row.hits == %{}
      assert row.diagnostics == 1
    end

    test "chains each tail into the next head with one snapshot per test after the initial read" do
      tid = new_table()

      snapshots = [
        %{Mod => [{10, 0}, {20, 0}]},
        %{Mod => [{10, 1}, {20, 0}]},
        %{Mod => [{10, 1}, {20, 1}]}
      ]

      {:ok, agent} = Agent.start_link(fn -> snapshots end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      snapshot_fn = fn _ ->
        Agent.get_and_update(agent, fn [snapshot | rest] -> {snapshot, rest} end)
      end

      arm(boundary_table: tid, snapshot_fn: snapshot_fn, modules_fn: fn -> [Mod] end)

      assert :armed = Boundary.head(%{module: T, test: :first})
      assert :ok = Boundary.tail(T, :first)

      # The second head reuses the first tail. A fourth snapshot would be
      # required here if the chained tail were not retained in ETS.
      assert :armed = Boundary.head(%{module: T, test: :second})
      assert :ok = Boundary.tail(T, :second)
      assert Agent.get(agent, & &1) == []

      assert [{_, first}] = :ets.lookup(tid, {T, :first})
      assert [{_, second}] = :ets.lookup(tid, {T, :second})
      assert first.hits == %{Mod => [10]}
      assert second.hits == %{Mod => [20]}
    end
  end

  describe "tail/2 - unarmed no-op" do
    test "returns :ok without writing when unarmed" do
      assert :ok = Boundary.tail(M, :t)
    end
  end
end
