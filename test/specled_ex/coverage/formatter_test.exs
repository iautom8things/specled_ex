defmodule SpecLedEx.Coverage.FormatterTest do
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.coverage_capture.anonymous_ets", "specled.coverage_capture.formatter_snapshot_fn_di", "specled.coverage_capture.keyed_by_test_pid"]

  alias SpecLedEx.Coverage
  alias SpecLedEx.Coverage.Formatter

  describe "init/1 + Coverage.init/install split" do
    test "init returns config without touching :cover or ETS" do
      config = Coverage.init([])

      assert is_function(config.snapshot_fn, 1)
      assert is_function(config.modules_fn, 0)
      assert config.snapshot_target == :_
      assert config.artifact_path == ".spec/_coverage/per_test.coverdata"
      refute Map.has_key?(config, :table)
    end

    test "init honors caller opts and host env overrides" do
      config =
        Coverage.init(
          [snapshot_target: :explicit, artifact_path: "/tmp/foo.coverdata"],
          modules_fn: fn -> [Foo, Bar] end
        )

      assert config.snapshot_target == :explicit
      assert config.artifact_path == "/tmp/foo.coverdata"
      assert config.modules_fn.() == [Foo, Bar]
    end

    test "install allocates an anonymous ETS table" do
      config = Coverage.init([])
      state = Coverage.install(config)

      assert is_reference(state.table)
      assert :ets.info(state.table, :named_table) == false
      assert :ets.info(state.table, :type) == :set

      :ets.delete(state.table)
    end

    test "two installs return distinct tables (no shared name)" do
      a = Coverage.install(Coverage.init([]))
      b = Coverage.install(Coverage.init([]))

      assert a.table != b.table

      :ets.delete(a.table)
      :ets.delete(b.table)
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

      {:ok, state} =
        Formatter.init(
          snapshot_fn: stub_fn,
          modules_fn: modules_fn,
          snapshot_target: :modules
        )

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

      {:ok, state} = Formatter.init(snapshot_fn: stub_fn)

      event =
        {:test_finished,
         %ExUnit.Test{module: M, name: :"test t", tags: %{file: "x.exs"}}}

      {:noreply, ^state} = Formatter.handle_cast(event, state)

      assert [{key, _record}] = :ets.tab2list(state.table)
      assert key == {M, :"test t"}

      :ets.delete(state.table)
    end
  end

  describe "suite_finished — flush" do
    test "writes per-file records derived from accumulated state" do
      tmp_path = Path.join(System.tmp_dir!(), "fmt_flush_#{System.unique_integer([:positive])}.coverdata")
      on_exit(fn -> File.rm_rf!(tmp_path) end)

      stub_fn = fn _ -> {:result, [], []} end
      pid = self()

      {:ok, state} =
        Formatter.init(
          snapshot_fn: stub_fn,
          artifact_path: tmp_path
        )

      tags = %{file: "test/abc_test.exs", test_pid: pid}

      event =
        {:test_finished,
         %ExUnit.Test{module: AbcTest, name: :"test x", tags: tags}}

      {:noreply, ^state} = Formatter.handle_cast(event, state)
      {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)

      assert File.exists?(tmp_path)

      records = SpecLedEx.Coverage.Store.read(tmp_path)
      assert is_list(records)
      assert length(records) >= 1

      record = hd(records)
      assert record.test_id == "AbcTest.test x"
      assert record.test_pid == pid
      assert record.tags == tags
      assert is_list(record.lines_hit)

      :ets.delete(state.table)
    end
  end
end
