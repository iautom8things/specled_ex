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
        mod = with_cover_compiled_module()

        mod.a(1)
        mod.a(1)
        mod.b(2)

        snapshot = Snapshot.native_snapshot([mod])
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
        mod = with_cover_compiled_module()
        mod.a(1)

        r1 = Snapshot.native_snapshot([mod])
        r2 = Snapshot.native_snapshot([mod])

        assert r1 == r2
      end
    end
  end

  describe "classic_snapshot/1" do
    @describetag :integration

    test "reads real line counts for a cover-compiled module via :cover.analyse/3, normalized" do
      mod = with_cover_compiled_module()

      mod.a(1)
      mod.a(1)
      mod.b(2)

      snapshot = Snapshot.classic_snapshot([mod])
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
      mod = with_cover_compiled_module()

      mod.a(1)
      mod.b(2)

      native = Snapshot.native_snapshot([mod]) |> Map.get(mod, []) |> Map.new()
      classic = Snapshot.classic_snapshot([mod]) |> Map.get(mod, []) |> Map.new()

      hit_lines_native = native |> Enum.filter(fn {_l, c} -> c > 0 end) |> Enum.map(&elem(&1, 0))

      hit_lines_classic =
        classic |> Enum.filter(fn {_l, c} -> c > 0 end) |> Enum.map(&elem(&1, 0))

      if native_coverage_supported?() do
        assert Enum.sort(hit_lines_native) == Enum.sort(hit_lines_classic)
      end
    end
  end

  # Compiles a fresh copy of LiveFixture's source to a real .beam on disk
  # (fresh module name per call so tests don't collide on shared cover
  # state) and cover-compiles it via :cover.compile_beam/1 -- the same path
  # `mix test --cover` uses for real application modules.
  defp with_cover_compiled_module do
    unique = System.unique_integer([:positive])
    mod_name = Module.concat(SpecLedEx.Coverage.SnapshotTestFixtures, "Live#{unique}")

    src = """
    defmodule #{inspect(mod_name)} do
      def a(x), do: x + 1
      def b(x), do: x * 2
    end
    """

    tmp_dir =
      System.tmp_dir!() |> Path.join("snapshot_test_fixture_#{unique}")

    File.mkdir_p!(tmp_dir)
    src_path = Path.join(tmp_dir, "fixture.ex")
    File.write!(src_path, src)

    # `mix test` (no `--cover`) defaults `debug_info: false`, but
    # `:cover.compile_beam/1` needs the abstract code that only debug_info
    # embeds -- flip it on for this compile only, then restore, since it's
    # a process-wide `Code` setting.
    prior_debug_info = Code.compiler_options()[:debug_info]
    Code.compiler_options(debug_info: true)
    [{^mod_name, bin}] = Code.compile_file(src_path)
    Code.compiler_options(debug_info: prior_debug_info)

    beam_path = Path.join(tmp_dir, "#{mod_name}.beam")
    File.write!(beam_path, bin)
    Code.append_path(tmp_dir)

    # `:cover` lives in the `:tools` OTP app, which plain `mix test` (no
    # `--cover`) does not put on the code path. `mix test --cover` itself
    # calls this before touching `:cover` (see
    # `Mix.Tasks.Test.Coverage.start/1`); we mirror that here since these
    # tests exercise the engine directly, without going through the real
    # `--cover` task.
    Mix.ensure_application!(:tools)

    case apply(:cover, :start, []) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    {:ok, ^mod_name} = apply(:cover, :compile_beam, [String.to_charlist(beam_path)])

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    mod_name
  end

  # `:code.coverage_support/0` only exists on OTP >= 27; calling it raw is an
  # UndefinedFunctionError on the classic-fallback CI leg (OTP 26). Mirror the
  # production guard (`Snapshot.coverage_support?/0`) without rescuing, so an
  # unexpected raise on a modern runtime still fails loudly.
  defp native_coverage_supported? do
    function_exported?(:code, :coverage_support, 0) and :code.coverage_support()
  end
end
