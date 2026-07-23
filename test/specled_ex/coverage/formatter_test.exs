defmodule SpecLedEx.Coverage.FormatterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  @moduletag spec: [
               "specled.coverage_capture.anonymous_ets",
               "specled.coverage_capture.formatter_snapshot_fn_di",
               "specled.coverage_capture.keyed_by_test_pid"
             ]

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.Formatter

  # Real, loadable module so `source_file/1` resolves to an actual path
  # instead of exercising the `nil`-source edge case.
  defmodule Fixture do
    @moduledoc false
    def noop, do: :ok
  end

  setup do
    on_exit(fn -> Application.delete_env(:specled_ex, :spec_cover_run) end)
    :ok
  end

  defp arm(seam_opts), do: Application.put_env(:specled_ex, :spec_cover_run, seam_opts)

  defp suite_started(state), do: elem(Formatter.handle_cast({:suite_started, %{}}, state), 1)

  describe "Coverage.init/2 — explicit opts validation, no implicit defaults" do
    test "raises without :snapshot_fn" do
      assert_raise ArgumentError, ~r/snapshot_fn/, fn ->
        Coverage.init([])
      end
    end

    test "resolves explicit opts into a config map, without touching :cover or ETS" do
      config = Coverage.init(snapshot_fn: fn _modules -> %{} end)

      assert is_function(config.snapshot_fn, 1)
      assert is_function(config.modules_fn, 0)
      assert config.artifact_path == ".spec/_coverage/per_test.coverdata"
      refute Map.has_key?(config, :table)
    end

    test "honors caller opts and host env overrides for the non-required fields" do
      config =
        Coverage.init(
          [snapshot_fn: fn _modules -> %{} end, artifact_path: "/tmp/foo.coverdata"],
          modules_fn: fn -> [Foo, Bar] end
        )

      assert config.artifact_path == "/tmp/foo.coverdata"
      assert config.modules_fn.() == [Foo, Bar]
    end

    test "install allocates an anonymous ETS table" do
      config = Coverage.init(snapshot_fn: fn _modules -> %{} end)
      state = Coverage.install(config)

      assert is_reference(state.table)
      assert :ets.info(state.table, :named_table) == false
      assert :ets.info(state.table, :type) == :set

      :ets.delete(state.table)
    end

    test "two installs return distinct tables (no shared name)" do
      opts = [snapshot_fn: fn _modules -> %{} end]
      a = Coverage.install(Coverage.init(opts))
      b = Coverage.install(Coverage.init(opts))

      assert a.table != b.table

      :ets.delete(a.table)
      :ets.delete(b.table)
    end
  end

  describe "Formatter.init/1 — disarmed by default" do
    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "without arming, init returns :disabled and prints exactly one stderr notice" do
      output =
        capture_io(:stderr, fn ->
          assert {:ok, :disabled} = Formatter.init([])
        end)

      lines = output |> String.trim_trailing("\n") |> String.split("\n")
      assert length(lines) == 1
      assert output =~ "disabled"
      assert output =~ "mix spec.cover.test"
    end

    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "every event no-ops in the :disabled state, never crashing or writing" do
      capture_io(:stderr, fn ->
        assert {:ok, :disabled} = Formatter.init([])
      end)

      test_struct = %ExUnit.Test{module: SomeTest, name: :"test x", tags: %{}}

      assert {:noreply, :disabled} = Formatter.handle_cast({:suite_started, %{}}, :disabled)

      assert {:noreply, :disabled} =
               Formatter.handle_cast({:test_finished, test_struct}, :disabled)

      assert {:noreply, :disabled} = Formatter.handle_cast({:suite_finished, %{}}, :disabled)
      assert {:noreply, :disabled} = Formatter.handle_cast(:some_other_event, :disabled)
    end
  end

  describe "Formatter.init/1 — armed path" do
    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "arming with `true` activates production defaults (native or classic engine)" do
      arm(true)

      assert {:ok, state} = Formatter.init([])

      assert is_function(state.snapshot_fn, 1)
      assert is_function(state.modules_fn, 0)
      assert state.artifact_path == ".spec/_coverage/per_test.coverdata"
      assert state.modules == nil
      assert state.last_snapshot == %{}
      assert state.diagnostic_count == 0
      refute state.degraded_async?

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "arming with a keyword list injects explicit config (test seam)" do
      stub_fn = fn _modules -> %{} end
      modules_fn = fn -> [Foo] end

      arm(snapshot_fn: stub_fn, modules_fn: modules_fn)

      assert {:ok, state} = Formatter.init([])

      assert state.snapshot_fn == stub_fn
      assert state.modules_fn == modules_fn

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "init/1's own argument is ignored — formatter opts come only from the :specled_ex seam" do
      smuggled_fn = fn _modules -> %{smuggled: true} end
      arm(true)

      assert {:ok, state} = Formatter.init(snapshot_fn: smuggled_fn)

      refute state.snapshot_fn == smuggled_fn

      :ets.delete(state.table)
    end
  end

  describe "suite_started — baseline capture" do
    test "calls modules_fn and snapshot_fn once each, storing the module scope, file map, and baseline" do
      parent = self()
      line = __ENV__.line

      modules_fn = fn ->
        send(parent, :modules_called)
        [Fixture]
      end

      snapshot_fn = fn modules ->
        send(parent, {:snapshot_called, modules})
        %{Fixture => [{line, 1}]}
      end

      arm(snapshot_fn: snapshot_fn, modules_fn: modules_fn)
      {:ok, state} = Formatter.init([])

      {:noreply, state} = Formatter.handle_cast({:suite_started, %{}}, state)

      assert_received :modules_called
      assert_received {:snapshot_called, [Fixture]}

      assert state.modules == [Fixture]
      assert state.last_snapshot == %{Fixture => [{line, 1}]}
      assert %{Fixture => file} = state.file_map
      assert file =~ "formatter_test.exs"

      :ets.delete(state.table)
    end
  end

  describe "test_finished — diff, compaction, and ETS storage" do
    test "diffs against the baseline, compacts hits to {file, sorted_lines}, and stores by test_pid" do
      pid = spawn(fn -> :ok end)
      line_a = __ENV__.line
      line_b = line_a + 1

      snapshots = [
        %{Fixture => [{line_a, 0}, {line_b, 0}]},
        %{Fixture => [{line_a, 2}, {line_b, 0}]}
      ]

      {:ok, agent} = Agent.start_link(fn -> snapshots end)

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(snapshot_fn: snapshot_fn, modules_fn: fn -> [Fixture] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      tags = %{file: "test/sample_test.exs", test_pid: pid}

      event =
        {:test_finished, %ExUnit.Test{module: SampleTest, name: :"test my_test", tags: tags}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      assert [{^pid, row}] = :ets.lookup(state.table, pid)
      assert row.test_id == "SampleTest.test my_test"
      assert row.tags == tags
      assert row.test_pid == pid
      assert row.files == [{__ENV__.file, [line_a]}]

      assert state.last_snapshot == %{Fixture => [{line_a, 2}, {line_b, 0}]}
      assert state.diagnostic_count == 0
      refute state.degraded_async?

      :ets.delete(state.table)
      Agent.stop(agent)
    end

    test "falls back to {module, name} key when test tags omit :test_pid" do
      arm(snapshot_fn: fn _modules -> %{} end, modules_fn: fn -> [] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      event =
        {:test_finished, %ExUnit.Test{module: M, name: :"test t", tags: %{file: "x.exs"}}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      assert [{key, _row}] = :ets.tab2list(state.table)
      assert key == {M, :"test t"}

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "a strictly-equal count (nothing hit this test) yields no file record" do
      arm(snapshot_fn: fn _modules -> %{Fixture => [{1, 1}]} end, modules_fn: fn -> [Fixture] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      event =
        {:test_finished, %ExUnit.Test{module: M, name: :"test t", tags: %{test_pid: self()}}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      assert [{_key, row}] = :ets.tab2list(state.table)
      assert row.files == []

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "a negative delta ('counters externally harvested') is diagnosed, not recorded as a hit" do
      {:ok, agent} =
        Agent.start_link(fn -> [%{Fixture => [{1, 5}]}, %{Fixture => [{1, 2}]}] end)

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(snapshot_fn: snapshot_fn, modules_fn: fn -> [Fixture] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      event =
        {:test_finished, %ExUnit.Test{module: M, name: :"test t", tags: %{test_pid: self()}}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      assert [{_key, row}] = :ets.tab2list(state.table)
      assert row.files == []
      assert state.diagnostic_count == 1

      :ets.delete(state.table)
      Agent.stop(agent)
    end

    test "a test whose tags carry async: true marks the run degraded" do
      arm(snapshot_fn: fn _modules -> %{} end, modules_fn: fn -> [] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      event =
        {:test_finished,
         %ExUnit.Test{module: M, name: :"test t", tags: %{test_pid: self(), async: true}}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      assert state.degraded_async?

      :ets.delete(state.table)
    end
  end

  describe "suite_finished — v2 :per_test envelope" do
    defp flush_with(snapshots) do
      tmp_path =
        Path.join(System.tmp_dir!(), "fmt_flush_#{System.unique_integer([:positive])}.coverdata")

      on_exit(fn -> File.rm_rf!(tmp_path) end)

      {:ok, agent} = Agent.start_link(fn -> snapshots end)

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn [head | tail] -> {head, tail} end)
      end

      arm(snapshot_fn: snapshot_fn, modules_fn: fn -> [Fixture] end, artifact_path: tmp_path)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      tags = %{file: "test/abc_test.exs", test_pid: self()}
      event = {:test_finished, %ExUnit.Test{module: AbcTest, name: :"test x", tags: tags}}
      {:noreply, state} = Formatter.handle_cast(event, state)

      output =
        capture_io(:stderr, fn ->
          {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)
        end)

      :ets.delete(state.table)
      Agent.stop(agent)

      {output, tmp_path}
    end

    test "real hits round-trip into a v2 :per_test envelope, with no stderr noise" do
      line = __ENV__.line
      {output, path} = flush_with([%{Fixture => [{line, 0}]}, %{Fixture => [{line, 1}]}])

      assert output == ""
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.version == 2
      assert envelope.mode == :per_test
      refute envelope.degraded
      assert envelope.files == [__ENV__.file]
      assert envelope.mfas == []

      assert [record] = envelope.payload
      assert record.test_id == "AbcTest.test x"
      assert record.file =~ "formatter_test.exs"
      assert record.lines_hit == [line]
    end

    test "genuinely no hits at all writes no artifact (empty-files refusal)" do
      {output, path} = flush_with([%{Fixture => [{1, 1}]}, %{Fixture => [{1, 1}]}])

      assert output =~ "no per-test coverage hits"
      refute File.exists?(path)
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "a negative-delta diagnostic marks the envelope degraded and prints a stderr notice" do
      line = __ENV__.line

      {output, path} =
        flush_with([
          %{Fixture => [{line, 5}, {line + 1, 0}]},
          %{Fixture => [{line, 2}, {line + 1, 1}]}
        ])

      assert output =~ "counters-externally-harvested"
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      # the real (increased) delta on the other line is still recorded honestly
      assert [record] = envelope.payload
      assert record.lines_hit == [line + 1]
    end
  end
end
