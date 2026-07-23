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
               "specled.coverage_capture.per_test_allow_async_degrade",
               "specled.coverage_capture.per_test_v2_envelope",
               "specled.coverage_capture.cumulative_parity"
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

      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :per_test
      refute envelope.degraded
      assert envelope.files != [], "expected at least one covered file"

      records = envelope.payload
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

      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :per_test

      assert envelope.degraded,
             "would fail if the formatter didn't flag the async-contaminated test's records, " <>
               "leaving the v2 envelope indistinguishable from a clean --per-test run"
    end
  end

  describe "cumulative-parity tripwire" do
    @tag :integration
    test "exported mix test --cover totals are byte-identical with and without --per-test armed" do
      root = scaffold_fixture(failing?: false)
      on_exit(fn -> File.rm_rf!(root) end)

      {plain_output, plain_status} =
        run_fixture_mix_test(root, ["test", "--cover", "--export-coverage", "parity_plain"])

      assert plain_status == 0,
             "expected plain mix test --cover to succeed. Output:\n#{plain_output}"

      {per_test_output, per_test_status} =
        run_fixture_mix_test(root, [
          "spec.cover.test",
          "--per-test",
          "--export-coverage",
          "parity_per_test"
        ])

      assert per_test_status == 0,
             "expected mix spec.cover.test --per-test to succeed. Output:\n#{per_test_output}"

      plain_coverdata = Path.join([root, "cover", "parity_plain.coverdata"])
      per_test_coverdata = Path.join([root, "cover", "parity_per_test.coverdata"])

      assert File.exists?(plain_coverdata)
      assert File.exists?(per_test_coverdata)

      # `:cover.export/1`'s own on-disk format embeds run-specific metadata
      # (observed: two exports of byte-identical coverage still differ at
      # the raw file level) so the meaningful comparison is the decoded
      # per-module, per-line call-count totals `:cover.import/1` +
      # `:cover.analyse/3` recover from each file -- exactly what `mix
      # test.coverage` and `SpecLedEx.Coverage.Aggregate.ingest/2` read.
      assert decode_coverdata(plain_coverdata) == decode_coverdata(per_test_coverdata),
             "would fail if arming the --per-test formatter (native or classic snapshot " <>
               "reads layered on top of the same :cover-instrumented modules) perturbed the " <>
               "cumulative totals `mix test --cover` exports on its own"
    end
  end

  # Decodes a `.coverdata` file's per-module, per-line call counts in
  # isolation (fresh `:cover.stop/0` + `:cover.start/0` + `:cover.import/1`),
  # for comparing two exports' actual coverage content rather than their
  # raw bytes. Mirrors `SpecLedEx.Coverage.Aggregate`'s
  # `:cover.modules/0` + `:cover.imported_modules/0` union: imported-only
  # data (no local cover-compile in this process) only shows up under
  # `imported_modules/0`.
  defp decode_coverdata(path) do
    Mix.ensure_application!(:tools)
    _ = apply(:cover, :stop, [])
    {:ok, _pid} = apply(:cover, :start, [])
    :ok = apply(:cover, :import, [String.to_charlist(path)])

    modules =
      (apply(:cover, :modules, []) ++ apply(:cover, :imported_modules, [])) |> Enum.uniq()

    result =
      modules
      |> Enum.flat_map(fn mod ->
        case apply(:cover, :analyse, [mod, :calls, :line]) do
          {:ok, entries} -> entries
          _ -> []
        end
      end)
      |> Enum.sort()

    apply(:cover, :stop, [])
    result
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
