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

  describe "Coverage.init/2 — explicit opts validation, no implicit defaults" do
    test "raises without :snapshot_fn" do
      assert_raise ArgumentError, ~r/snapshot_fn/, fn ->
        Coverage.init(snapshot_target: :_)
      end
    end

    test "raises without :snapshot_target" do
      assert_raise ArgumentError, ~r/snapshot_target/, fn ->
        Coverage.init(snapshot_fn: fn _ -> :ok end)
      end
    end

    test "resolves explicit opts into a config map, without touching :cover or ETS" do
      config = Coverage.init(snapshot_fn: fn _ -> :ok end, snapshot_target: :_)

      assert is_function(config.snapshot_fn, 1)
      assert is_function(config.modules_fn, 0)
      assert config.snapshot_target == :_
      assert config.artifact_path == ".spec/_coverage/per_test.coverdata"
      refute Map.has_key?(config, :table)
    end

    test "honors caller opts and host env overrides for the non-required fields" do
      config =
        Coverage.init(
          [
            snapshot_fn: fn _ -> :ok end,
            snapshot_target: :explicit,
            artifact_path: "/tmp/foo.coverdata"
          ],
          modules_fn: fn -> [Foo, Bar] end
        )

      assert config.snapshot_target == :explicit
      assert config.artifact_path == "/tmp/foo.coverdata"
      assert config.modules_fn.() == [Foo, Bar]
    end

    test "install allocates an anonymous ETS table" do
      config = Coverage.init(snapshot_fn: fn _ -> :ok end, snapshot_target: :_)
      state = Coverage.install(config)

      assert is_reference(state.table)
      assert :ets.info(state.table, :named_table) == false
      assert :ets.info(state.table, :type) == :set

      :ets.delete(state.table)
    end

    test "two installs return distinct tables (no shared name)" do
      opts = [snapshot_fn: fn _ -> :ok end, snapshot_target: :_]
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

      assert {:noreply, :disabled} =
               Formatter.handle_cast({:test_finished, test_struct}, :disabled)

      assert {:noreply, :disabled} = Formatter.handle_cast({:suite_finished, %{}}, :disabled)
      assert {:noreply, :disabled} = Formatter.handle_cast(:some_other_event, :disabled)
    end
  end

  describe "Formatter.init/1 — armed path" do
    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "arming with `true` activates production defaults (activates as before)" do
      arm(true)

      assert {:ok, state} = Formatter.init([])

      assert is_function(state.snapshot_fn, 1)
      assert state.snapshot_target == :_
      assert state.artifact_path == ".spec/_coverage/per_test.coverdata"

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "arming with a keyword list injects explicit config (test seam)" do
      stub_fn = fn _ -> :stub_result end
      modules_fn = fn -> [Foo] end

      arm(snapshot_fn: stub_fn, modules_fn: modules_fn, snapshot_target: :modules)

      assert {:ok, state} = Formatter.init([])

      assert state.snapshot_fn == stub_fn
      assert state.modules_fn == modules_fn
      assert state.snapshot_target == :modules

      :ets.delete(state.table)
    end

    @tag spec: "specled.coverage_capture.formatter_arming_seam"
    test "init/1's own argument is ignored — formatter opts come only from the :specled_ex seam" do
      smuggled_fn = fn _ -> :smuggled end
      arm(true)

      assert {:ok, state} = Formatter.init(snapshot_fn: smuggled_fn, snapshot_target: :modules)

      refute state.snapshot_fn == smuggled_fn
      assert state.snapshot_target == :_

      :ets.delete(state.table)
    end
  end

  describe "test_finished — formatter_stub_snapshot scenario" do
    test "calls snapshot_fn exactly once with the cover module set and stores the record under test_pid" do
      parent = self()
      pid = spawn(fn -> :ok end)
      stub_return = {:result, [{{Sample, 1}, 1}], []}

      stub_fn = fn arg ->
        send(parent, {:snapshot_called, arg})
        stub_return
      end

      modules_fn = fn -> [Sample, Other] end

      arm(snapshot_fn: stub_fn, modules_fn: modules_fn, snapshot_target: :modules)
      {:ok, state} = Formatter.init([])

      tags = %{file: "test/sample_test.exs", test_pid: pid, custom: :marker}

      event =
        {:test_finished,
         %ExUnit.Test{
           module: SampleTest,
           name: :"test my_test",
           tags: tags
         }}

      {:noreply, ^state} = Formatter.handle_cast(event, state)

      assert_received {:snapshot_called, [Sample, Other]}
      refute_received {:snapshot_called, _}, "snapshot_fn must be called exactly once"

      assert :ets.lookup(state.table, pid) == [
               {pid, {stub_return, tags, "SampleTest.test my_test"}}
             ]

      :ets.delete(state.table)
    end

    test "falls back to {module, name} key when test tags omit :test_pid" do
      stub_fn = fn _ -> :stub end
      arm(snapshot_fn: stub_fn, snapshot_target: :_)
      {:ok, state} = Formatter.init([])

      event =
        {:test_finished, %ExUnit.Test{module: M, name: :"test t", tags: %{file: "x.exs"}}}

      {:noreply, ^state} = Formatter.handle_cast(event, state)

      assert [{key, _record}] = :ets.tab2list(state.table)
      assert key == {M, :"test t"}

      :ets.delete(state.table)
    end
  end

  describe "suite_finished — flush honest behavior (fabrication gone)" do
    defp flush_with(stub_fn) do
      tmp_path =
        Path.join(System.tmp_dir!(), "fmt_flush_#{System.unique_integer([:positive])}.coverdata")

      on_exit(fn -> File.rm_rf!(tmp_path) end)

      arm(snapshot_fn: stub_fn, snapshot_target: :_, artifact_path: tmp_path)
      {:ok, state} = Formatter.init([])

      tags = %{file: "test/abc_test.exs", test_pid: self()}
      event = {:test_finished, %ExUnit.Test{module: AbcTest, name: :"test x", tags: tags}}

      {:noreply, ^state} = Formatter.handle_cast(event, state)

      output =
        capture_io(:stderr, fn ->
          {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)
        end)

      :ets.delete(state.table)

      {output, SpecLedEx.Coverage.Store.read(tmp_path)}
    end

    test "real line-level coverage round-trips to a record, with no stderr noise" do
      line = __ENV__.line

      {output, records} = flush_with(fn _ -> {:result, [{{Fixture, line}, 1}], []} end)

      assert output == ""
      assert [record] = records
      assert record.test_id == "AbcTest.test x"
      assert record.file =~ "formatter_test.exs"
      assert record.lines_hit == [line]
    end

    test "genuinely empty coverage ({:result, [], []}) yields zero records, no placeholder" do
      {output, records} = flush_with(fn _ -> {:result, [], []} end)

      assert output == ""
      assert records == []
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "an MFA-shaped (function-level) entry never produces a {file, 0} record" do
      {output, records} = flush_with(fn _ -> {:result, [{{Fixture, :noop, 0}, 5}], []} end)

      assert records == []
      assert output =~ "1 snapshot decode error"
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "a never-executed function (call count 0) is absent from records, not fabricated" do
      {output, records} = flush_with(fn _ -> {:result, [{{Fixture, :noop, 0}, 0}], []} end)

      assert records == []
      assert output =~ "1 snapshot decode error"
    end

    @tag spec: "specled.coverage_capture.formatter_no_fabrication"
    test "an unrecognized whole-snapshot shape is counted as a decode error and surfaced, not laundered" do
      {output, records} = flush_with(fn _ -> {:error, :not_cover_compiled} end)

      assert records == []
      assert output =~ "1 snapshot decode error"
    end
  end
end
