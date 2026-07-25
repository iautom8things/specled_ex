defmodule SpecLedEx.Coverage.MfaLinesTest do
  # covers: specled.coverage_capture.mfa_lines_index
  # Flips the VM-global :debug_info compiler option — must not race.
  use ExUnit.Case, async: false

  @moduletag spec: ["specled.coverage_capture.mfa_lines_index"]

  alias SpecLedEx.Coverage.MfaLines

  setup do
    tmp = Path.join(System.tmp_dir!(), "mfa_lines_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Code.prepend_path(tmp)

    on_exit(fn ->
      for file <- File.ls!(tmp) do
        path = Path.join(tmp, file)

        if String.ends_with?(file, ".beam") do
          mod =
            file
            |> String.replace_suffix(".beam", "")
            |> String.to_atom()

          :code.purge(mod)
          :code.delete(mod)
        end

        _ = File.rm(path)
      end

      _ = File.rmdir(tmp)
      Code.delete_path(tmp)
    end)

    %{tmp: tmp}
  end

  describe "index/1" do
    test "indexes a compiled-in fixture module's known function line sets from abstract_code", %{
      tmp: tmp
    } do
      {mod, source_path} = compile_fixture(tmp, "Alpha")

      index = MfaLines.index([mod])
      fun_index = Map.fetch!(index, mod)
      assert is_map(fun_index)

      alpha_lines = Map.fetch!(fun_index, {:alpha, 1})
      beta_lines = Map.fetch!(fun_index, {:beta, 2})
      gamma_lines = Map.fetch!(fun_index, {:gamma, 0})

      # Line numbers come from the fixture source written below.
      assert MapSet.member?(alpha_lines, 2)
      assert MapSet.member?(beta_lines, 3)
      assert MapSet.member?(beta_lines, 4)
      assert MapSet.member?(beta_lines, 5)
      assert MapSet.member?(gamma_lines, 8)

      # Would fail if index collapsed multi-line bodies to a single head
      # line: beta/2's body spans three lines, and per-test MFA reach
      # intersects lines_hit against this set — a head-only index would
      # miss hits on interior body lines and under-count covered MFAs in
      # CoverageClosure.build_v2/2.
      assert MapSet.size(beta_lines) >= 3
      assert File.regular?(source_path)
    end

    test "returns :no_debug_info for a module that is not loaded / has no object code" do
      # A module atom that was never compiled has no object code, so the
      # index must surface :no_debug_info rather than silently returning
      # %{} (which would look like "zero functions, all uncovered").
      ghost = SpecLedEx.Coverage.MfaLinesTest.NeverCompiledGhostModule

      index = MfaLines.index([ghost])
      assert index[ghost] == :no_debug_info
    end

    test "indexes multiple modules independently; a :no_debug_info sibling does not poison others",
         %{tmp: tmp} do
      {mod, _path} = compile_fixture(tmp, "Beta")
      ghost = SpecLedEx.Coverage.MfaLinesTest.AnotherGhostModule
      index = MfaLines.index([mod, ghost])

      assert is_map(index[mod])
      assert Map.has_key?(index[mod], {:alpha, 1})
      assert index[ghost] == :no_debug_info
    end
  end

  # Compile a small fixture with debug_info so abstract_code is present,
  # write the beam under `tmp`, and load from disk so
  # `:code.get_object_code/1` resolves (same pattern as binding_test.exs).
  defp compile_fixture(tmp, suffix) do
    uniq = :erlang.unique_integer([:positive])
    mod_str = "SpecLedEx.Coverage.MfaLinesTest.Fixture#{suffix}#{uniq}"
    mod = Module.concat([mod_str])

    source_path = Path.join(tmp, "fixture_#{suffix}.ex")

    File.write!(source_path, """
    defmodule #{mod_str} do
      def alpha(x), do: x + 1
      def beta(x, y) do
        z = x + y
        z * 2
      end

      def gamma, do: :ok
    end
    """)

    prior = Code.compiler_options()[:debug_info]
    Code.put_compiler_option(:debug_info, true)

    [{^mod, binary}] =
      try do
        Code.compile_file(source_path)
      after
        Code.put_compiler_option(:debug_info, prior)
      end

    beam_path = Path.join(tmp, Atom.to_string(mod) <> ".beam")
    File.write!(beam_path, binary)
    :code.purge(mod)
    :code.delete(mod)
    {:module, ^mod} = :code.load_binary(mod, String.to_charlist(beam_path), binary)

    {mod, source_path}
  end
end
