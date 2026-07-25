defmodule SpecLedEx.Coverage.FormatterTest do
  # Shares Application env arming seam with other coverage tests — must not race.
  use ExUnit.Case, async: false

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
      assert state.baseline == %{}
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
      assert state.baseline == %{Fixture => [{line, 1}]}
      assert %{Fixture => file} = state.file_map

      source = Fixture.module_info(:compile)[:source] |> List.to_string()
      assert file == Path.relative_to_cwd(source)

      :ets.delete(state.table)
    end
  end

  describe "test_finished — inventory only (no per-test snapshot)" do
    @tag spec: "specled.coverage_capture.formatter_auditor"
    test "records inventory without calling snapshot_fn again" do
      pid = spawn(fn -> :ok end)
      parent = self()
      line = __ENV__.line

      snapshot_fn = fn _modules ->
        send(parent, :snapshot_called)
        %{Fixture => [{line, 0}]}
      end

      arm(snapshot_fn: snapshot_fn, modules_fn: fn -> [Fixture] end)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      # suite_started already called snapshot once
      assert_received :snapshot_called

      tags = %{file: "test/sample_test.exs", test_pid: pid}

      event =
        {:test_finished, %ExUnit.Test{module: SampleTest, name: :"test my_test", tags: tags}}

      {:noreply, state} = Formatter.handle_cast(event, state)

      # Would fail if test_finished still took a per-test snapshot (lazy capture).
      refute_received :snapshot_called

      assert [{^pid, row}] = :ets.lookup(state.table, pid)
      assert row.test_id == "SampleTest.test my_test"
      assert row.test_key == {SampleTest, :"test my_test"}
      assert row.module == SampleTest
      assert row.tags == tags
      assert row.test_pid == pid
      refute Map.has_key?(row, :files)

      refute state.degraded_async?

      :ets.delete(state.table)
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

  describe "suite_finished — auditor flush, remainder, unhooked degrade" do
    defp tmp_artifact do
      path =
        Path.join(
          System.tmp_dir!(),
          "fmt_auditor_#{System.unique_integer([:positive])}/per_test.coverdata"
        )

      File.mkdir_p!(Path.dirname(path))
      on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)
      path
    end

    defp new_boundary_table do
      tid = :ets.new(:anon, [:public, :set])
      on_exit(fn -> if :ets.info(tid) != :undefined, do: :ets.delete(tid) end)
      tid
    end

    defp flush_suite(opts) do
      snapshots = Keyword.fetch!(opts, :snapshots)
      tests = Keyword.get(opts, :tests, [])
      boundary_rows = Keyword.get(opts, :boundary_rows, [])
      boundary_tid = Keyword.get(opts, :boundary_table)
      modules = Keyword.get(opts, :modules, [Fixture])

      tmp_path = tmp_artifact()

      agent = start_supervised!({Agent, fn -> snapshots end})

      snapshot_fn = fn _modules ->
        Agent.get_and_update(agent, fn
          [head | tail] -> {head, tail}
          [] -> {%{}, []}
        end)
      end

      seam =
        [
          snapshot_fn: snapshot_fn,
          modules_fn: fn -> modules end,
          artifact_path: tmp_path
        ]
        |> then(fn s ->
          if boundary_tid, do: Keyword.put(s, :boundary_table, boundary_tid), else: s
        end)

      if boundary_tid do
        Enum.each(boundary_rows, fn {key, row} ->
          true = :ets.insert(boundary_tid, {key, row})
        end)
      end

      arm(seam)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)

      state =
        Enum.reduce(tests, state, fn test, st ->
          elem(Formatter.handle_cast({:test_finished, test}, st), 1)
        end)

      output =
        capture_io(:stderr, fn ->
          {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)
        end)

      :ets.delete(state.table)

      {output, tmp_path}
    end

    @tag spec: [
           "specled.coverage_capture.boundary_row_exclusive",
           "specled.coverage_capture.envelope_meta",
           "specled.coverage_capture.formatter_auditor"
         ]
    test "flush derives hooked records exclusively from boundary; envelope meta.boundary is true" do
      line_boundary = __ENV__.line
      line_other = line_boundary + 1
      boundary_tid = new_boundary_table()

      true =
        :ets.insert(
          boundary_tid,
          {{AbcTest, :"test x"}, %{hits: %{Fixture => [line_boundary]}, diagnostics: 0}}
        )

      # Baseline → final increases both lines; only boundary line is attributed.
      snapshots = [
        %{Fixture => [{line_boundary, 0}, {line_other, 0}]},
        %{Fixture => [{line_boundary, 1}, {line_other, 1}]}
      ]

      tags = %{file: "test/abc_test.exs", test_pid: self()}
      test = %ExUnit.Test{module: AbcTest, name: :"test x", tags: tags}

      {output, path} =
        flush_suite(
          snapshots: snapshots,
          tests: [test],
          boundary_table: boundary_tid,
          boundary_rows: []
        )

      # remainder notice should not fire for a fully-hooked single test
      refute output =~ "ran without the per-test boundary hook"

      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.meta[:boundary] == true
      assert [record] = envelope.payload
      # Would fail if flush ignored the boundary row.
      assert record.lines_hit == [line_boundary]
      refute line_other in record.lines_hit
      # Unattributed remainder holds the non-boundary line.
      assert {_, rem_lines} =
               Enum.find(envelope.meta[:unattributed] || [], fn {f, _} ->
                 f =~ "formatter_test.exs"
               end)

      assert line_other in rem_lines
      refute envelope.degraded
      refute Map.has_key?(envelope.meta, :degraded_reasons)
    end

    @tag spec: [
           "specled.coverage_capture.envelope_meta",
           "specled.coverage_capture.formatter_auditor",
           "specled.coverage_capture.path_identity",
           "specled.coverage_capture.unmapped_modules_meta"
         ]
    test "flush uses repo-relative source identities and surfaces hit modules absent from its single file map" do
      mapped_line = __ENV__.line
      unmapped_line = mapped_line + 1
      boundary_tid = new_boundary_table()
      unmapped = UnloadableCoverageModule

      true =
        :ets.insert(
          boundary_tid,
          {{IdentityTest, :"test x"},
           %{
             hits: %{Fixture => [mapped_line], unmapped => [unmapped_line]},
             diagnostics: 0
           }}
        )

      snapshots = [
        %{Fixture => [{mapped_line, 0}], unmapped => [{unmapped_line, 0}]},
        %{Fixture => [{mapped_line, 1}], unmapped => [{unmapped_line, 1}]}
      ]

      test = %ExUnit.Test{
        module: IdentityTest,
        name: :"test x",
        tags: %{file: "test/identity_test.exs", test_pid: self()}
      }

      {_output, path} =
        flush_suite(
          snapshots: snapshots,
          tests: [test],
          modules: [Fixture, unmapped],
          boundary_table: boundary_tid
        )

      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert [record] = envelope.payload
      refute Path.type(record.file) == :absolute
      assert record.file == Path.relative_to_cwd(__ENV__.file)
      assert envelope.meta.unmapped_modules == [unmapped]

      refute Enum.any?(envelope.meta[:unattributed] || [], fn {_file, lines} ->
               unmapped_line in lines
             end)
    end

    @tag spec: [
           "specled.coverage_capture.unhooked_degrade",
           "specled.coverage_capture.unhooked_remediation_notice",
           "specled.coverage_capture.formatter_auditor"
         ]
    test "unhooked module degrades the run and the notice names the setup line" do
      line = __ENV__.line

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 2}]}
      ]

      tags = %{file: "test/unhooked_test.exs", test_pid: self()}
      test = %ExUnit.Test{module: UnhookedTest, name: :"test x", tags: tags}

      {output, path} = flush_suite(snapshots: snapshots, tests: [test])

      # Named discoverability: notice names the module and the exact setup line.
      assert output =~ "UnhookedTest"
      assert output =~ "ran without the per-test boundary hook"
      assert output =~ "setup {SpecLedEx.Coverage, :per_test_boundary}"
      assert output =~ "SpecLedEx.Case"

      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert envelope.meta[:unhooked_modules] == [UnhookedTest]
      assert envelope.payload == []
      # Zero hooked rows + non-empty remainder still writes.
      assert envelope.files != []
      assert envelope.meta[:unattributed] != [] and envelope.meta[:unattributed] != nil
    end

    @tag spec: [
           "specled.coverage_capture.unhooked_degrade",
           "specled.coverage_capture.formatter_auditor"
         ]
    test "zero-hooked run with remainder still writes a degraded envelope" do
      line = __ENV__.line

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 1}]}
      ]

      tests = [
        %ExUnit.Test{module: ATest, name: :"test one", tags: %{test_pid: self()}},
        %ExUnit.Test{
          module: ATest,
          name: :"test two",
          tags: %{test_pid: spawn(fn -> :ok end)}
        }
      ]

      {output, path} = flush_suite(snapshots: snapshots, tests: tests)

      assert output =~ "2 tests in ATest"
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert envelope.payload == []
      assert envelope.meta[:unhooked_modules] == [ATest]
      # Single-cause degrade records exactly its one cause.
      assert envelope.meta[:degraded_reasons] == [:unhooked]
      assert File.exists?(path)
    end

    @tag spec: [
           "specled.coverage_capture.degraded_reasons",
           "specled.coverage_capture.scenario.degraded_reasons_overlap"
         ]
    test "async + unhooked overlap records both causes in meta.degraded_reasons" do
      line = __ENV__.line

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 1}]}
      ]

      # async-tagged AND unhooked (no boundary row) in the same run — the
      # overlap the consumer previously reconstructed wrongly by elimination.
      test = %ExUnit.Test{
        module: OverlapTest,
        name: :"test x",
        tags: %{async: true, test_pid: self()}
      }

      {_output, path} = flush_suite(snapshots: snapshots, tests: [test])

      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert :async in envelope.meta[:degraded_reasons]
      assert :unhooked in envelope.meta[:degraded_reasons]
    end

    @tag spec: [
           "specled.coverage_capture.degraded_reasons",
           "specled.coverage_capture.scenario.degraded_reasons_overlap"
         ]
    test "harvest-only degrade records [:counters_harvested]" do
      line = __ENV__.line
      boundary_tid = new_boundary_table()

      true =
        :ets.insert(
          boundary_tid,
          {{HarvestTest, :"test x"}, %{hits: %{Fixture => [line]}, diagnostics: 1}}
        )

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 1}]}
      ]

      test = %ExUnit.Test{module: HarvestTest, name: :"test x", tags: %{test_pid: self()}}

      {output, path} =
        flush_suite(snapshots: snapshots, tests: [test], boundary_table: boundary_tid)

      assert output =~ "counters-externally-harvested"
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert envelope.meta[:degraded_reasons] == [:counters_harvested]
    end

    @tag spec: [
           "specled.coverage_capture.never_ran_not_inventoried",
           "specled.coverage_capture.scenario.never_ran_not_inventoried"
         ]
    test "excluded/skipped/invalid tests are never inventoried and cannot degrade a fully hooked run" do
      line = __ENV__.line
      boundary_tid = new_boundary_table()

      true =
        :ets.insert(
          boundary_tid,
          {{RanTest, :"test ran"}, %{hits: %{Fixture => [line]}, diagnostics: 0}}
        )

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 1}]}
      ]

      ran = %ExUnit.Test{module: RanTest, name: :"test ran", tags: %{test_pid: self()}}

      # `async: true` on the never-ran tests also proves the degraded_async?
      # fold skips them — ExUnit merges module tags into tests it never runs.
      never_ran =
        for {name, state} <- [
              {:"test excluded", {:excluded, "due to --only"}},
              {:"test skipped", {:skipped, "@tag :skip"}},
              {:"test invalid", {:invalid, RanTest}}
            ] do
          %ExUnit.Test{
            module: RanTest,
            name: name,
            state: state,
            tags: %{async: true, test_pid: self()}
          }
        end

      {output, path} =
        flush_suite(
          snapshots: snapshots,
          tests: [ran | never_ran],
          boundary_table: boundary_tid
        )

      refute output =~ "ran without the per-test boundary hook"
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      refute envelope.degraded
      refute Map.has_key?(envelope.meta, :unhooked_modules)
      refute Map.has_key?(envelope.meta, :degraded_reasons)
    end

    @tag spec: [
           "specled.coverage_capture.never_ran_not_inventoried",
           "specled.coverage_capture.scenario.never_ran_not_inventoried"
         ]
    test "a failed test ran — it stays inventoried and still degrades when unhooked" do
      line = __ENV__.line

      snapshots = [
        %{Fixture => [{line, 0}]},
        %{Fixture => [{line, 1}]}
      ]

      failed = %ExUnit.Test{
        module: FailedTest,
        name: :"test boom",
        state: {:failed, []},
        tags: %{test_pid: self()}
      }

      {output, path} = flush_suite(snapshots: snapshots, tests: [failed])

      assert output =~ "FailedTest"
      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert envelope.meta[:unhooked_modules] == [FailedTest]
    end

    @tag spec: "specled.coverage_capture.formatter_auditor"
    test "genuinely empty run (no hits) writes no artifact" do
      snapshots = [
        %{Fixture => [{1, 1}]},
        %{Fixture => [{1, 1}]}
      ]

      test = %ExUnit.Test{module: EmptyTest, name: :"test x", tags: %{test_pid: self()}}
      {output, path} = flush_suite(snapshots: snapshots, tests: [test])

      assert output =~ "no per-test coverage hits"
      refute File.exists?(path)
    end

    @tag spec: [
           "specled.coverage_capture.formatter_no_fabrication",
           "specled.coverage_capture.snapshot_negative_delta_diagnostic"
         ]
    test "suite-level negative delta diagnoses and marks degraded" do
      line = __ENV__.line

      # baseline count 5 → final count 2: externally harvested
      snapshots = [
        %{Fixture => [{line, 5}]},
        %{Fixture => [{line, 2}]}
      ]

      boundary_tid = new_boundary_table()
      # No boundary rows, but also no inventory hits → empty remainder, no write
      # unless we attribute something. Use an empty inventory with a decrease
      # that produces diagnostics only (no positive hits).
      {output, path} = flush_suite(snapshots: snapshots, tests: [], boundary_table: boundary_tid)

      assert output =~ "counters-externally-harvested"
      # No positive hits → empty files refusal
      refute File.exists?(path)
    end

    @tag spec: [
           "specled.coverage_capture.unhooked_degrade",
           "specled.coverage_capture.unhooked_remediation_notice"
         ]
    test "partial hook: hooked payload exact; unhooked module audited" do
      line_hooked = __ENV__.line
      line_unhooked = line_hooked + 1
      boundary_tid = new_boundary_table()

      true =
        :ets.insert(
          boundary_tid,
          {{HookedTest, :"test hooked"}, %{hits: %{Fixture => [line_hooked]}, diagnostics: 0}}
        )

      snapshots = [
        %{Fixture => [{line_hooked, 0}, {line_unhooked, 0}]},
        %{Fixture => [{line_hooked, 1}, {line_unhooked, 1}]}
      ]

      tests = [
        %ExUnit.Test{
          module: HookedTest,
          name: :"test hooked",
          tags: %{file: "hooked.exs", test_pid: self()}
        },
        %ExUnit.Test{
          module: UnhookedTest,
          name: :"test bare",
          tags: %{file: "bare.exs", test_pid: spawn(fn -> :ok end)}
        }
      ]

      {output, path} =
        flush_suite(
          snapshots: snapshots,
          tests: tests,
          boundary_table: boundary_tid
        )

      assert output =~ "UnhookedTest"
      assert output =~ "setup {SpecLedEx.Coverage, :per_test_boundary}"
      refute output =~ "HookedTest ran without"

      assert {:ok, envelope} = SpecLedEx.Coverage.Store.read_v2(path)
      assert envelope.degraded
      assert envelope.meta[:unhooked_modules] == [UnhookedTest]
      assert envelope.meta[:boundary] == true

      assert [record] = envelope.payload
      assert record.test_id =~ "HookedTest"
      assert record.lines_hit == [line_hooked]

      assert {_, rem} =
               Enum.find(envelope.meta[:unattributed], fn {f, _} -> f =~ "formatter_test" end)

      assert line_unhooked in rem
      refute line_hooked in rem
    end

    @tag spec: "specled.coverage_capture.formatter_auditor"
    test "snapshot_fn called only at suite_started and suite_finished (not per test)" do
      parent = self()
      line = __ENV__.line
      calls = :ets.new(:anon, [:public, :set])
      on_exit(fn -> if :ets.info(calls) != :undefined, do: :ets.delete(calls) end)

      snapshot_fn = fn _modules ->
        :ets.update_counter(calls, :n, {2, 1}, {:n, 0})
        send(parent, :snap)
        %{Fixture => [{line, 0}]}
      end

      tmp_path = tmp_artifact()
      arm(snapshot_fn: snapshot_fn, modules_fn: fn -> [Fixture] end, artifact_path: tmp_path)
      {:ok, state} = Formatter.init([])
      state = suite_started(state)
      assert_received :snap

      test1 = %ExUnit.Test{module: T, name: :"test a", tags: %{test_pid: self()}}
      test2 = %ExUnit.Test{module: T, name: :"test b", tags: %{test_pid: spawn(fn -> :ok end)}}

      {:noreply, state} = Formatter.handle_cast({:test_finished, test1}, state)
      {:noreply, state} = Formatter.handle_cast({:test_finished, test2}, state)
      refute_received :snap

      capture_io(:stderr, fn ->
        {:noreply, ^state} = Formatter.handle_cast({:suite_finished, %{}}, state)
      end)

      assert_received :snap
      assert [{:n, 2}] = :ets.lookup(calls, :n)

      :ets.delete(state.table)
    end
  end
end
