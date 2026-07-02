defmodule SpecLedEx.Integration.TracerIncrementalMergeTest do
  # Drives real subprocess compiles of a scratch project; serial by nature.
  use ExUnit.Case, async: false

  @moduletag :integration

  @etf_relative Path.join(["_build", "test", ".spec", "xref_mfa.etf"])

  @tag :tmp_dir
  @tag timeout: to_timeout(minute: 5)
  @tag spec: "specled.compiler_tracer.merge_on_flush"
  test "incremental compile preserves the full callee graph (equals force compile)", %{
    tmp_dir: tmp_dir
  } do
    root = scaffold_project!(tmp_dir)

    compile!(root)
    etf_full = read_etf!(root)

    assert caller_modules(etf_full) == [FixtureA, FixtureB, FixtureC],
           "full compile should trace all three modules, got: #{inspect(etf_full)}"

    # Content change — a bare `touch` does not recompile on checksum-based Mix.
    File.write!(
      Path.join(root, "lib/fixture_b.ex"),
      """
      defmodule FixtureB do
        def mid(x), do: FixtureC.leaf(x + 1)
      end
      """
    )

    compile!(root)
    etf_incremental = read_etf!(root)

    File.rm_rf!(Path.join(root, "_build"))
    compile!(root)
    etf_force = read_etf!(root)

    assert etf_incremental == etf_force,
           "incremental manifest diverged from force-compile manifest.\n" <>
             "incremental: #{inspect(etf_incremental)}\nforce: #{inspect(etf_force)}"

    assert caller_modules(etf_incremental) == [FixtureA, FixtureB, FixtureC]
  end

  @tag :tmp_dir
  @tag timeout: to_timeout(minute: 5)
  @tag spec: "specled.compiler_tracer.seed_time_ghost_prune"
  test "deleted module's entries are pruned by the second subsequent compile", %{
    tmp_dir: tmp_dir
  } do
    root = scaffold_project!(tmp_dir)

    compile!(root)
    assert FixtureC in caller_modules(read_etf!(root))

    # Delete C and drop B's call to it. This compile's seed-prune runs against
    # the pre-deletion compile manifest, so C's entries may lag one compile —
    # only the final state after the *next* compile is asserted.
    File.rm!(Path.join(root, "lib/fixture_c.ex"))

    File.write!(
      Path.join(root, "lib/fixture_b.ex"),
      """
      defmodule FixtureB do
        def mid(x), do: String.duplicate("b", x)
      end
      """
    )

    compile!(root)

    File.write!(
      Path.join(root, "lib/fixture_a.ex"),
      """
      defmodule FixtureA do
        def run(x), do: FixtureB.mid(x + 1)
      end
      """
    )

    compile!(root)

    refute FixtureC in caller_modules(read_etf!(root)),
           "ghost entries for the deleted module survived two compiles: " <>
             inspect(read_etf!(root))
  end

  defp scaffold_project!(tmp_dir) do
    root = Path.join(tmp_dir, "merge_fixture")
    File.mkdir_p!(Path.join(root, "lib"))

    File.write!(Path.join(root, "mix.exs"), """
    defmodule MergeFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :merge_fixture,
          version: "0.1.0",
          elixir: "~> 1.15",
          start_permanent: false,
          elixirc_options: [tracers: tracers()],
          deps: []
        ]
      end

      def application, do: []

      defp tracers do
        if Code.ensure_loaded?(SpecLedEx.Compiler.Tracer) do
          [SpecLedEx.Compiler.Tracer]
        else
          []
        end
      end
    end
    """)

    File.write!(Path.join(root, "lib/fixture_a.ex"), """
    defmodule FixtureA do
      def run(x), do: FixtureB.mid(x)
    end
    """)

    File.write!(Path.join(root, "lib/fixture_b.ex"), """
    defmodule FixtureB do
      def mid(x), do: FixtureC.leaf(x)
    end
    """)

    File.write!(Path.join(root, "lib/fixture_c.ex"), """
    defmodule FixtureC do
      def leaf(x), do: String.duplicate("c", x)
    end
    """)

    root
  end

  defp compile!(root) do
    parent_lib = Path.expand("_build/#{Mix.env()}/lib")

    {output, status} =
      System.cmd("mix", ["compile"],
        cd: root,
        env: [{"MIX_ENV", "test"}, {"ERL_LIBS", parent_lib}],
        stderr_to_stdout: true
      )

    assert status == 0, "fixture compile failed:\n#{output}"

    assert File.exists?(Path.join(root, @etf_relative)),
           "tracer manifest missing after compile — is the tracer on the code path? " <>
             "output:\n#{output}"

    output
  end

  defp read_etf!(root) do
    root
    |> Path.join(@etf_relative)
    |> File.read!()
    |> :erlang.binary_to_term()
  end

  defp caller_modules(edges) do
    edges
    |> Map.keys()
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
