Code.require_file("../../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule SpecLedEx.Coverage.AggregateTest do
  # `SpecLedEx.Coverage.Aggregate.ingest/2` drives real `:cover` stop/start/
  # import cycles, which would corrupt this suite's own coverage state if run
  # in-process (see the epic's "never :cover.reset" guardrail). Every real
  # ingest here runs in a child BEAM via IntegrationCase, exercised through
  # `mix spec.cover.ingest` — the same production entry point a caller uses,
  # so this is a real production-path smoke test, not seam-only coverage.
  use SpecLedEx.IntegrationCase, async: false

  @moduletag spec: [
               "specled.coverage_capture.aggregate_ingest",
               "specled.coverage_capture.aggregate_empty_coverage"
             ]

  alias SpecLedEx.Coverage.Store

  describe "aggregate_ingest_child_beam scenario" do
    @tag :integration
    test "ingests a real .coverdata into a v2 envelope with nonempty files+mfas, round-tripping via Store" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {export_output, export_status} =
        run_fixture_mix_test(root, ["test", "--cover", "--export-coverage", "specled"])

      assert export_status == 0,
             "expected fixture `mix test --cover --export-coverage` to succeed, got #{export_status}.\nOutput:\n#{export_output}"

      coverdata = Path.join(root, "cover/specled.coverdata")
      assert File.exists?(coverdata), "expected #{coverdata} to exist after export"

      envelope_path = Path.join(root, "out.coverdata")

      {ingest_output, ingest_status} =
        run_fixture_mix_test(root, [
          "spec.cover.ingest",
          "cover/specled.coverdata",
          "--output",
          "out.coverdata"
        ])

      assert ingest_status == 0,
             "expected mix spec.cover.ingest to succeed, got #{ingest_status}.\nOutput:\n#{ingest_output}"

      assert {:ok, envelope} = Store.read_v2(envelope_path)

      assert envelope.version == 2
      assert envelope.mode == :aggregate
      assert envelope.degraded == false
      assert envelope.files != []
      assert envelope.mfas != []

      file_entry = Enum.find(envelope.files, &(&1.file == "lib/covered.ex"))
      assert file_entry, "expected an entry for lib/covered.ex, got: #{inspect(envelope.files)}"
      assert file_entry.lines_hit != []

      mfa_strings = Enum.map(envelope.mfas, & &1.mfa)
      assert "Covered.add/2" in mfa_strings

      add_entry = Enum.find(envelope.mfas, &(&1.mfa == "Covered.add/2"))
      assert add_entry.covered == true

      hello_entry = Enum.find(envelope.mfas, &(&1.mfa == "Covered.hello/0"))
      assert hello_entry.covered == false

      assert {:ok, _stats} = Store.read_status(envelope_path)
    end
  end

  describe "aggregate_ingest_empty_coverage scenario" do
    @tag :integration
    test "ingesting an eventless .coverdata reports empty coverage and refuses to write" do
      root = scaffold_empty_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {export_output, export_status} =
        run_fixture_mix_test(root, ["test", "--cover", "--export-coverage", "empty"])

      assert export_status == 0,
             "expected fixture `mix test --cover --export-coverage` to succeed, got #{export_status}.\nOutput:\n#{export_output}"

      coverdata = Path.join(root, "cover/empty.coverdata")
      assert File.exists?(coverdata), "expected #{coverdata} to exist after export"

      {ingest_output, ingest_status} =
        run_fixture_mix_test(root, ["spec.cover.ingest", "cover/empty.coverdata"])

      assert ingest_status != 0,
             "expected mix spec.cover.ingest to fail on empty coverage, got status 0.\nOutput:\n#{ingest_output}"

      assert ingest_output =~ "empty coverage",
             "expected the empty-coverage refusal message. Output was:\n#{ingest_output}"

      status_target = Path.join(root, Store.default_path())
      assert {:refused, _reason} = Store.read_status(status_target)
    end
  end

  defp scaffold_fixture do
    base = new_fixture_root("specled_aggregate_fixture")

    File.mkdir_p!(Path.join(base, "lib"))
    File.write!(Path.join([base, "lib", "covered.ex"]), lib_module())
    File.write!(Path.join([base, "test", "covered_test.exs"]), covered_test_module())

    base
  end

  # A fixture with no `lib/` modules at all: `mix test --cover
  # --export-coverage` still runs and exports a `.coverdata`, but it carries
  # zero cover-compiled modules — the eventless input
  # `Aggregate.ingest/2` must refuse as `:empty_coverage`.
  defp scaffold_empty_fixture do
    base = new_fixture_root("specled_aggregate_empty_fixture")
    File.write!(Path.join([base, "test", "noop_test.exs"]), noop_test_module())
    base
  end

  defp new_fixture_root(prefix) do
    base =
      System.tmp_dir!()
      |> Path.join("#{prefix}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs(prefix))
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")

    base
  end

  defp mix_exs(prefix) do
    """
    defmodule #{Macro.camelize(prefix)}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{prefix},
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

  defp noop_test_module do
    """
    defmodule NoopTest do
      use ExUnit.Case, async: false

      test "trivial" do
        assert 1 + 1 == 2
      end
    end
    """
  end
end
