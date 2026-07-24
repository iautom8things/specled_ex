defmodule SpecLedEx.Coverage.SnapshotTest do
  use ExUnit.Case, async: false

  @moduletag spec: [
               "specled.coverage_capture.snapshot_runtime_mode",
               "specled.coverage_capture.snapshot_diff_strictly_increased",
               "specled.coverage_capture.snapshot_negative_delta_diagnostic"
             ]

  alias SpecLedEx.Coverage.Snapshot

  # Real module compiled into a real .beam on disk (required by
  # :cover.compile_beam/1 -- it recompiles from the abstract code embedded
  # in an on-disk .beam, not an in-memory module) so both engines can be
  # exercised against real, cover-compiled code.
  defmodule LiveFixture do
    @moduledoc false
    def a(x), do: x + 1
    def b(x), do: x * 2
  end

  describe "runtime_mode/0" do
    test "reflects :code.coverage_support/0" do
      assert Snapshot.runtime_mode() ==
               if(native_coverage_supported?(), do: :native, else: :classic)
    end
  end

  describe "scope_modules/0" do
    test "delegates to Coverage.cover_modules_safe/0 (never raises, even with :cover unstarted)" do
      assert is_list(Snapshot.scope_modules())
    end
  end

  describe "native_snapshot/1" do
    @describetag :integration

    test "reads real line counts for a cover-compiled module via :code.get_coverage(:line, _)" do
      unless native_coverage_supported?() do
        # decision 4: never hard-gate. On a runtime without native support
        # this scenario simply cannot be exercised; classic_snapshot/1
        # below covers the fallback engine instead.
        :ok
      else
        {mod, snapshot} =
          cover_snapshot_in_child("""
          mod.a(1)
          mod.a(1)
          mod.b(2)

          result = SpecLedEx.Coverage.Snapshot.native_snapshot([mod])
          """)

        assert %{^mod => lines} = snapshot
        assert is_list(lines)
        assert Enum.all?(lines, fn {line, count} -> is_integer(line) and is_integer(count) end)
        # no synthetic {mod, 0}-style line-zero entry in native's flat shape
        refute Enum.any?(lines, fn {line, _count} -> line == 0 end)
      end
    end

    test "a module that is not loaded, or not cover-compiled, yields [] rather than raising" do
      assert Snapshot.native_snapshot([NoSuchModuleAtAll]) == %{NoSuchModuleAtAll => []}
      assert Snapshot.native_snapshot([Enum]) == %{Enum => []}
    end

    test "repeated reads with nothing else touching :cover are idempotent (no drain side effect)" do
      unless native_coverage_supported?() do
        :ok
      else
        {_mod, {r1, r2}} =
          cover_snapshot_in_child("""
          mod.a(1)

          r1 = SpecLedEx.Coverage.Snapshot.native_snapshot([mod])
          r2 = SpecLedEx.Coverage.Snapshot.native_snapshot([mod])
          result = {r1, r2}
          """)

        assert r1 == r2
      end
    end
  end

  describe "classic_snapshot/1" do
    @describetag :integration

    test "reads real line counts for a cover-compiled module via :cover.analyse/3, normalized" do
      {mod, snapshot} =
        cover_snapshot_in_child("""
        mod.a(1)
        mod.a(1)
        mod.b(2)

        result = SpecLedEx.Coverage.Snapshot.classic_snapshot([mod])
        """)

      assert %{^mod => lines} = snapshot
      assert is_list(lines)
      refute Enum.any?(lines, fn {line, _count} -> line == 0 end)
      assert Enum.any?(lines, fn {_line, count} -> count > 0 end)
    end

    test "a module never cover-compiled yields [] rather than an {:error, _} tuple" do
      assert Snapshot.classic_snapshot([NoSuchModuleAtAll]) == %{NoSuchModuleAtAll => []}
    end
  end

  describe "diff/2 — strictly-increased counts only" do
    test "a line hit is only recorded when the count strictly increases" do
      prev = %{Mod => [{1, 0}, {2, 3}, {3, 5}]}
      curr = %{Mod => [{1, 1}, {2, 3}, {3, 7}]}

      assert {hits, diagnostics} = Snapshot.diff(prev, curr)
      assert hits == %{Mod => [1, 3]}
      assert diagnostics == []
    end

    test "a module or line absent from prev defaults its baseline count to 0" do
      prev = %{}
      curr = %{Mod => [{5, 1}]}

      assert {%{Mod => [5]}, []} = Snapshot.diff(prev, curr)
    end

    test "a module with only unchanged counts contributes no entry to hits at all" do
      prev = %{Mod => [{1, 4}]}
      curr = %{Mod => [{1, 4}]}

      assert {hits, []} = Snapshot.diff(prev, curr)
      refute Map.has_key?(hits, Mod)
    end

    @tag spec: "specled.coverage_capture.snapshot_negative_delta_diagnostic"
    test "a strictly-decreased count is a diagnostic, never a negative/garbage hit" do
      prev = %{Mod => [{1, 5}]}
      curr = %{Mod => [{1, 2}]}

      assert {hits, [diagnostic]} = Snapshot.diff(prev, curr)
      refute Map.has_key?(hits, Mod)
      assert diagnostic.reason == :counters_externally_harvested
      assert diagnostic.module == Mod
      assert diagnostic.line == 1
      assert diagnostic.prev == 5
      assert diagnostic.curr == 2
    end

    test "mixed increase and decrease within the same module: real hit kept, decrease diagnosed" do
      prev = %{Mod => [{1, 5}, {2, 0}]}
      curr = %{Mod => [{1, 2}, {2, 1}]}

      assert {hits, [diagnostic]} = Snapshot.diff(prev, curr)
      assert hits == %{Mod => [2]}
      assert diagnostic.line == 1
    end
  end

  describe "native/classic parity" do
    @describetag :integration

    test "both engines agree on which lines were hit for the same exercised module" do
      {_mod, {native, classic}} =
        cover_snapshot_in_child("""
        mod.a(1)
        mod.b(2)

        native = SpecLedEx.Coverage.Snapshot.native_snapshot([mod]) |> Map.get(mod, []) |> Map.new()
        classic = SpecLedEx.Coverage.Snapshot.classic_snapshot([mod]) |> Map.get(mod, []) |> Map.new()
        result = {native, classic}
        """)

      hit_lines_native = native |> Enum.filter(fn {_l, c} -> c > 0 end) |> Enum.map(&elem(&1, 0))

      hit_lines_classic =
        classic |> Enum.filter(fn {_l, c} -> c > 0 end) |> Enum.map(&elem(&1, 0))

      if native_coverage_supported?() do
        assert Enum.sort(hit_lines_native) == Enum.sort(hit_lines_classic)
      end
    end
  end

  @child_begin "SNAPSHOT_CHILD_BEGIN"
  @child_end "SNAPSHOT_CHILD_END"

  # Compiles a fresh fixture module's source to a real .beam on disk,
  # cover-compiles it, runs `exercise_source` against it, and reads back
  # whatever `exercise_source` binds to `result` -- ALL inside a fully
  # separate OS process (its own `:cover` coordinator), never the host
  # BEAM's shared `:cover` server that an outer `mix test --cover` run
  # depends on.
  #
  # An earlier revision did this cover-compile in-process (host BEAM) and
  # deleted the fixture's source dir on `on_exit`. Harmless standalone,
  # but under an outer `mix test --cover` the module stayed registered in
  # the host's `:cover` coordinator after its source was gone: it leaked
  # into the final tally as a spurious 100% row AND crashed the HTML
  # report generator with `{:no_source_code_found, Live*}` -- which in
  # turn masked the threshold gate's own non-zero exit code (`:cover`
  # exposes no supported way to unregister a single already-compiled
  # module short of stopping the whole coordinator, which would tear
  # down the outer run's own coverage). Quarantining the whole
  # compile+exercise+read cycle in a child process (mirroring
  # `decode_coverdata/1`'s fix in specled_-aav) means the fixture module
  # is never seen by the host's `:cover` server at all, so it can't leak
  # into anything the host reports.
  #
  # `exercise_source` is spliced into the child script with `mod` already
  # bound to the fixture module's name; it must assign its answer to
  # `result` (any term -- round-tripped back to the host as
  # `Base64(term_to_binary(result))`).
  defp cover_snapshot_in_child(exercise_source) do
    unique = System.unique_integer([:positive])
    mod_name = Module.concat(SpecLedEx.Coverage.SnapshotTestFixtures, "Live#{unique}")

    tmp_dir = System.tmp_dir!() |> Path.join("snapshot_child_fixture_#{unique}")
    File.mkdir_p!(tmp_dir)
    src_path = Path.join(tmp_dir, "fixture.ex")

    File.write!(src_path, """
    defmodule #{inspect(mod_name)} do
      def a(x), do: x + 1
      def b(x), do: x * 2
    end
    """)

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    # ERL_LIBS (not -pa) so the child resolves SpecLedEx.Coverage.Snapshot
    # (and any dependency it needs) the same way
    # SpecLedEx.IntegrationCase.run_fixture_mix_test/2 already does for
    # other quarantined child-BEAM runs in this suite.
    parent_lib = Path.expand("_build/#{Mix.env()}/lib")

    script = """
    mod = #{inspect(mod_name)}
    tmp_dir = #{inspect(tmp_dir)}
    src_path = #{inspect(src_path)}

    # `mix test` (no `--cover`) defaults `debug_info: false`, but
    # `:cover.compile_beam/1` needs the abstract code that only debug_info
    # embeds -- flip it on for this compile (a fresh, one-shot process, so
    # there is nothing to restore it for afterwards).
    Code.compiler_options(debug_info: true)
    [{^mod, bin}] = Code.compile_file(src_path)

    beam_path = Path.join(tmp_dir, "\#{mod}.beam")
    File.write!(beam_path, bin)
    Code.append_path(tmp_dir)

    {:ok, _pid} = :cover.start()
    {:ok, ^mod} = :cover.compile_beam(String.to_charlist(beam_path))

    #{exercise_source}

    encoded = result |> :erlang.term_to_binary() |> Base.encode64()
    IO.write(["#{@child_begin}", encoded, "#{@child_end}"])
    """

    {output, status} =
      System.cmd("elixir", ["-e", script],
        env: [{"ERL_LIBS", parent_lib}],
        stderr_to_stdout: true
      )

    assert status == 0,
           "expected child-BEAM snapshot run to exit 0, got #{status}.\nOutput:\n#{output}"

    assert output =~ @child_begin and output =~ @child_end,
           "child run exited 0 but produced no output markers.\nOutput:\n#{output}"

    [_before, rest] = String.split(output, @child_begin, parts: 2)
    [encoded, _after] = String.split(rest, @child_end, parts: 2)

    {mod_name, encoded |> Base.decode64!() |> :erlang.binary_to_term()}
  end

  # `:code.coverage_support/0` only exists on OTP >= 27; calling it raw is an
  # UndefinedFunctionError on the classic-fallback CI leg (OTP 26). Mirror the
  # production guard (`Snapshot.coverage_support?/0`) without rescuing, so an
  # unexpected raise on a modern runtime still fails loudly.
  defp native_coverage_supported? do
    function_exported?(:code, :coverage_support, 0) and :code.coverage_support()
  end
end
