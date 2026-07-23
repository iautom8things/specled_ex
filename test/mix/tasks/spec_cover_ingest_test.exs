Code.require_file("../../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule Mix.Tasks.Spec.Cover.IngestTest do
  # IntegrationCase compiles shared test/fixtures projects and drives the
  # task via a child BEAM, matching Mix.Tasks.Spec.Cover.TestTest — real
  # `:cover` interaction never runs in the host test process.
  use SpecLedEx.IntegrationCase, async: false

  @moduletag spec: ["specled.tasks.cover_ingest_escape_hatch"]

  alias SpecLedEx.Coverage.Store

  describe "spec.cover.ingest CLI" do
    @tag :integration
    test "mix help spec.cover.ingest exits 0 and documents the task" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["help", "spec.cover.ingest"])

      assert status == 0,
             "expected `mix help spec.cover.ingest` to exit 0, got #{status}.\nOutput:\n#{output}"

      assert output =~ "spec.cover.ingest"
    end

    @tag :integration
    test "a missing coverdata path exits non-zero with a clear message" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} =
        run_fixture_mix_test(root, ["spec.cover.ingest", "no/such/file.coverdata"])

      assert status != 0,
             "expected a missing path to fail. Output:\n#{output}"

      assert output =~ "no such file",
             "expected a clear missing-file message. Output was:\n#{output}"
    end

    @tag :integration
    test "a garbage coverdata path exits non-zero with a clear message" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      garbage_path = Path.join(root, "garbage.coverdata")
      File.write!(garbage_path, "this is not a coverdata file")

      {output, status} = run_fixture_mix_test(root, ["spec.cover.ingest", "garbage.coverdata"])

      assert status != 0,
             "expected a garbage file to fail. Output:\n#{output}"

      assert output =~ "failed to import",
             "expected a clear import-failure message. Output was:\n#{output}"
    end

    @tag :integration
    test "ingesting a real export writes the v2 envelope and reports success" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {export_output, export_status} =
        run_fixture_mix_test(root, ["test", "--cover", "--export-coverage", "specled"])

      assert export_status == 0,
             "expected fixture export to succeed. Output:\n#{export_output}"

      {ingest_output, ingest_status} =
        run_fixture_mix_test(root, ["spec.cover.ingest", "cover/specled.coverdata"])

      assert ingest_status == 0,
             "expected mix spec.cover.ingest to succeed. Output:\n#{ingest_output}"

      assert ingest_output =~ "Wrote",
             "expected a success message naming the written artifact. Output was:\n#{ingest_output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert File.exists?(artifact), "expected the default artifact path to be written"
      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :aggregate
    end
  end

  defp scaffold_fixture do
    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_ingest_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "lib", "covered.ex"]), lib_module())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")
    File.write!(Path.join([base, "test", "covered_test.exs"]), covered_test_module())

    base
  end

  defp mix_exs do
    """
    defmodule SpecledCoverIngestFixture.MixProject do
      use Mix.Project

      def project do
        [
          app: :specled_cover_ingest_fixture,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end

      def application, do: []
    end
    """
  end

  defp lib_module do
    """
    defmodule Covered do
      def add(a, b), do: a + b
      def hello, do: :world
    end
    """
  end

  defp covered_test_module do
    """
    defmodule CoveredTest do
      use ExUnit.Case, async: false

      test "add/2 is exercised" do
        assert Covered.add(1, 2) == 3
      end
    end
    """
  end
end
