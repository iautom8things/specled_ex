Code.require_file("../../../test_support/specled_ex_integration_case.ex", __DIR__)

defmodule Mix.Tasks.Spec.Cover.TestTest do
  # IntegrationCase compiles shared test/fixtures projects.
  use SpecLedEx.IntegrationCase, async: false

  @moduletag spec: [
               "specled.coverage_capture.integration_case",
               "specled.coverage_capture.default_aggregate_run",
               "specled.coverage_capture.default_aggregate_red_suite_passthrough",
               "specled.coverage_capture.default_aggregate_empty_refusal",
               "specled.coverage_capture.serialized_run",
               "specled.coverage_capture.per_test_async_contamination",
               "specled.coverage_capture.per_test_allow_async_degrade"
             ]

  alias SpecLedEx.Coverage.Store

  describe "default mode (aggregate ingest)" do
    @tag :integration
    test "mix help spec.cover.test exits 0 and keeps the task name" do
      root = scaffold_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["help", "spec.cover.test"])

      assert status == 0,
             "expected `mix help spec.cover.test` to exit 0, got #{status}.\nOutput:\n#{output}"

      assert output =~ "spec.cover.test"
    end

    @tag :integration
    test "green suite: plain mix test --cover --export-coverage, no formatter, ingests aggregate envelope" do
      root = scaffold_fixture(failing?: false)
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test"])

      assert status == 0,
             "expected mix spec.cover.test to succeed, got status #{status}.\nOutput:\n#{output}"

      refute output =~ "[spec.cover.test --per-test]",
             "default mode must not touch the per-test formatter/async machinery. Output:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert File.exists?(artifact), "expected #{artifact} to exist. Output:\n#{output}"

      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :aggregate
      assert envelope.files != []
      assert envelope.mfas != []

      assert {:ok, stats} = Store.read_status(artifact)
      assert stats.mode == :aggregate
    end

    @tag :integration
    test "red suite: exit code passes through and real (non-placeholder) coverage still ingests" do
      root = scaffold_fixture(failing?: true)
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test"])

      assert status != 0,
             "expected a failing suite to propagate a non-zero exit code. Output:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")

      assert File.exists?(artifact),
             "expected the exported coverage (real, from application code the failing suite " <>
               "still exercised) to be ingested despite the red suite. Output:\n#{output}"

      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :aggregate
      assert envelope.files != [], "would fail if a red suite's real coverage were discarded"
    end

    @tag :integration
    test "empty coverage: non-zero exit naming the refusal, status reports :refused" do
      root = scaffold_empty_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test"])

      assert status != 0,
             "expected zero cover-compiled modules to refuse and exit non-zero. Output:\n#{output}"

      assert output =~ "empty coverage",
             "expected a clear empty-coverage refusal message. Output was:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")

      assert match?({:refused, _}, Store.read_status(artifact)),
             "would fail if a refused ingest left no sidecar (indistinguishable from never ran)"
    end
  end

  describe "--per-test mode (opt-in serialized capture)" do
    @tag :integration
    test "runs serialized, arms the formatter, writes per_test.coverdata" do
      root = scaffold_fixture(async_true?: false)
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test", "--per-test"])

      assert status == 0,
             "expected --per-test to succeed on a non-contaminated fixture, got #{status}.\nOutput:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert File.exists?(artifact), "expected #{artifact} to exist. Output:\n#{output}"

      records = Store.read(artifact)
      assert is_list(records)
      assert records != [], "expected at least one per-test record"

      Enum.each(records, fn rec ->
        assert is_binary(rec.test_id)
        assert is_binary(rec.file)
        assert is_list(rec.lines_hit)
        assert is_map(rec.tags)
        assert is_pid(rec.test_pid)
      end)
    end

    @tag :integration
    test "async contamination without --allow-async exits non-zero naming the file" do
      root = scaffold_async_true_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test", "--per-test"])

      assert status != 0,
             "would fail if async: true contamination of serialized per-test capture were " <>
               "silently allowed to corrupt attribution. Output:\n#{output}"

      assert output =~ "async_true_test.exs",
             "expected the contaminated file to be named. Output was:\n#{output}"
    end

    @tag :integration
    test "--allow-async degrades instead of failing: exits 0 with a warning" do
      root = scaffold_async_true_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} =
        run_fixture_mix_test(root, ["spec.cover.test", "--per-test", "--allow-async"])

      assert status == 0,
             "expected --allow-async to degrade rather than fail. Output:\n#{output}"

      assert output =~ "WARNING",
             "expected a degraded-run warning naming the contaminated file. Output:\n#{output}"

      assert output =~ "async_true_test.exs"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert File.exists?(artifact), "expected the degraded run to still write an artifact"
    end
  end

  defp scaffold_fixture(opts \\ []) do
    failing? = Keyword.get(opts, :failing?, false)
    async_true? = Keyword.get(opts, :async_true?, false)

    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "lib", "covered.ex"]), lib_module())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(
      Path.join([base, "test", "default_test.exs"]),
      default_test_module(failing?)
    )

    if async_true? do
      File.write!(
        Path.join([base, "test", "async_true_test.exs"]),
        async_true_test_module()
      )
    end

    base
  end

  defp scaffold_async_true_fixture do
    base = scaffold_fixture(failing?: false)

    File.write!(
      Path.join([base, "test", "async_true_test.exs"]),
      async_true_test_module()
    )

    base
  end

  defp scaffold_empty_fixture do
    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_empty_fixture_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(
      Path.join([base, "test", "trivial_test.exs"]),
      """
      defmodule TrivialTest do
        use ExUnit.Case, async: false

        test "no application code touched" do
          assert 1 + 1 == 2
        end
      end
      """
    )

    base
  end

  defp mix_exs do
    """
    defmodule SpecledCoverFixture.MixProject do
      use Mix.Project

      def project do
        ensure_specled_loaded()

        [
          app: :specled_cover_fixture,
          version: "0.1.0",
          elixir: "~> 1.18",
          deps: []
        ]
      end

      def application, do: []

      defp ensure_specled_loaded do
        case System.get_env("SPECLED_EX_EBIN") do
          nil -> :ok
          path -> Code.append_path(String.to_charlist(path))
        end
      end
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

  defp default_test_module(failing?) do
    assertion =
      if failing?, do: "assert Covered.hello() == :nope", else: "assert Covered.hello() == :world"

    """
    defmodule DefaultTest do
      use ExUnit.Case, async: false

      setup do
        {:ok, test_pid: self()}
      end

      test "covered.hello" do
        #{assertion}
      end

      test "covered.add returns sum" do
        assert Covered.add(1, 2) == 3
      end
    end
    """
  end

  defp async_true_test_module do
    """
    defmodule AsyncTrueTest do
      use ExUnit.Case, async: true

      setup do
        {:ok, test_pid: self()}
      end

      test "covered.add returns sum" do
        assert Covered.add(1, 2) == 3
      end
    end
    """
  end
end
