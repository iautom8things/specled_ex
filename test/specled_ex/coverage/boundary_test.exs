defmodule SpecLedEx.Coverage.BoundaryTest do
  # Shares Application env arming seam with other coverage tests — must not race.
  use ExUnit.Case, async: false

  @moduletag spec: [
               "specled.coverage_capture.boundary_hook_sync",
               "specled.coverage_capture.boundary_noop_unarmed"
             ]

  alias SpecLedEx.Coverage.Boundary

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
  end

  describe "head/1 + tail/3 — window diff semantics" do
    test "inserts hits for lines that strictly increased in the window" do
      tid = new_table()

      snapshots = [
        %{Mod => [{10, 0}, {20, 0}]},
        %{Mod => [{10, 2}, {20, 0}]}
      ]

      {:ok, agent} = Agent.start_link(fn -> snapshots end)
      on_exit(fn -> if Process.alive?(agent), do: Agent.stop(agent) end)

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(
        boundary_table: tid,
        snapshot_fn: snapshot_fn,
        modules_fn: fn -> [Mod] end
      )

      head = Boundary.head(%{module: SampleTest, test: :"test path_a"})
      assert head == %{Mod => [{10, 0}, {20, 0}]}

      assert :ok =
               Boundary.tail({SampleTest, :"test path_a"}, head, %{file: "test/sample_test.exs"})

      assert [{_key, row}] =
               :ets.lookup(tid, {SampleTest, :"test path_a"})

      assert row.hits == %{Mod => [10]}
      assert row.diagnostics == 0
      assert row.tags.file == "test/sample_test.exs"
    end

    test "caches modules_fn result once under the reserved key" do
      tid = new_table()
      parent = self()

      arm(
        boundary_table: tid,
        snapshot_fn: fn _ -> %{} end,
        modules_fn: fn ->
          send(parent, :modules_called)
          [ModA, ModB]
        end
      )

      _ = Boundary.head(%{})
      _ = Boundary.head(%{})
      assert_received :modules_called
      refute_received :modules_called

      assert [{_, [ModA, ModB]}] = :ets.lookup(tid, Boundary.modules_cache_key())
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

      head = Boundary.head(%{})
      assert :ok = Boundary.tail({T, :t}, head, %{})

      assert [{_, row}] = :ets.lookup(tid, {T, :t})
      assert row.hits == %{}
      assert row.diagnostics == 1
    end
  end

  describe "tail/3 — unarmed no-op" do
    test "returns :ok without writing when unarmed" do
      assert :ok = Boundary.tail({M, :t}, %{}, %{})
    end
  end
end
