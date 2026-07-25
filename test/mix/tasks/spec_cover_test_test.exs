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
               "specled.coverage_capture.per_test_artifact_freshness",
               "specled.coverage_capture.cumulative_parity",
               "specled.coverage_capture.per_test_exclusive_attribution",
               "specled.coverage_capture.boundary_row_exclusive",
               "specled.coverage_capture.boundary_hook_sync",
               "specled.coverage_capture.case_template",
               "specled.coverage_capture.formatter_auditor",
               "specled.coverage_capture.unhooked_degrade",
               "specled.coverage_capture.unhooked_remediation_notice"
             ]

  alias SpecLedEx.Coverage.Store

  describe "per-test artifact freshness predicate" do
    @tag spec: "specled.coverage_capture.per_test_artifact_freshness"
    test "classifies missing, refused, stale successful, and fresh successful artifacts" do
      root =
        System.tmp_dir!()
        |> Path.join("specled_cover_freshness_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(root) end)

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      suite_started_at = ~U[2026-01-01 00:00:00Z]

      refute Mix.Tasks.Spec.Cover.Test.per_test_artifact_fresh?(artifact, suite_started_at)

      refused =
        Store.build_envelope(%{
          mode: :per_test,
          generated_at: ~U[2026-01-01 00:00:01Z],
          source: "refused",
          files: [],
          mfas: [],
          payload: [],
          degraded: false
        })

      assert {:error, :empty_files} = Store.write_v2(refused, artifact)
      refute Mix.Tasks.Spec.Cover.Test.per_test_artifact_fresh?(artifact, suite_started_at)

      stale =
        Store.build_envelope(%{
          mode: :per_test,
          generated_at: ~U[2020-01-01 00:00:00Z],
          source: "stale",
          files: ["lib/stale.ex"],
          mfas: [],
          payload: [],
          degraded: false
        })

      :ok = Store.write_v2(stale, artifact)
      refute Mix.Tasks.Spec.Cover.Test.per_test_artifact_fresh?(artifact, suite_started_at)

      fresh =
        Store.build_envelope(%{
          mode: :per_test,
          generated_at: ~U[2026-01-01 00:00:01Z],
          source: "fresh",
          files: ["lib/fresh.ex"],
          mfas: [],
          payload: [],
          degraded: false
        })

      :ok = Store.write_v2(fresh, artifact)
      assert Mix.Tasks.Spec.Cover.Test.per_test_artifact_fresh?(artifact, suite_started_at)
    end
  end

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
      # Fully-hooked fixture: without SpecLedEx.Case wiring the auditor folds
      # all coverage to the remainder and degrades. The exclusive fixture is
      # fully hooked; here we use that shape so a clean --per-test run still
      # produces a non-degraded envelope with per-test records.
      root = scaffold_exclusive_fixture()
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

    @tag :integration
    @tag spec: "specled.coverage_capture.per_test_artifact_freshness"
    test "a stale successful artifact cannot make a formatter run with no fresh write exit 0" do
      root = scaffold_empty_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")

      stale =
        Store.build_envelope(%{
          mode: :per_test,
          generated_at: ~U[2020-01-01 00:00:00Z],
          source: "stale",
          files: ["lib/stale.ex"],
          mfas: [],
          payload: [],
          degraded: false
        })

      :ok = Store.write_v2(stale, artifact)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test", "--per-test"])

      assert status != 0,
             "would fail if run_per_test/2 accepted the previous run's artifact. Output:\n#{output}"

      assert output =~ "coverage artifact is stale"
      assert {:ok, %{generated_at: ~U[2020-01-01 00:00:00Z]}} = Store.read_v2(artifact)
    end

    @tag :integration
    @tag spec: "specled.coverage_capture.per_test_artifact_freshness"
    test "a red per-test suite preserves its failing exit without inventing a stale-artifact failure" do
      root = scaffold_exclusive_fixture(failing?: true)
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test", "--per-test"])

      assert status != 0
      refute output =~ "coverage artifact is stale"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert {:ok, envelope} = Store.read_v2(artifact)
      assert DateTime.after?(envelope.generated_at, ~U[2020-01-01 00:00:00Z])
    end
  end

  describe "partial-hook unhooked degrade (auditor)" do
    @tag :integration
    @tag spec: [
           "specled.coverage_capture.unhooked_degrade",
           "specled.coverage_capture.unhooked_remediation_notice",
           "specled.coverage_capture.formatter_auditor"
         ]
    test "unhooked module degrades the run and the notice names the setup line" do
      # One hooked module (SpecLedEx.Case) + one unhooked bare ExUnit.Case.
      # Would fail if the auditor still used lazy per-test snapshots for
      # unhooked tests, or if unhooked modules failed the run instead of
      # degrading with a remediation notice.
      root = scaffold_partial_hook_fixture()
      on_exit(fn -> File.rm_rf!(root) end)

      {output, status} = run_fixture_mix_test(root, ["spec.cover.test", "--per-test"])

      assert status == 0,
             "expected partial-hook --per-test to exit 0 (degrade, never fail). Output:\n#{output}"

      assert output =~ "UnhookedTest",
             "expected stderr notice to name the unhooked module. Output:\n#{output}"

      assert output =~ "setup {SpecLedEx.Coverage, :per_test_boundary}",
             "expected notice to name the exact setup line. Output:\n#{output}"

      artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
      assert File.exists?(artifact), "expected degraded artifact. Output:\n#{output}"

      assert {:ok, envelope} = Store.read_v2(artifact)
      assert envelope.mode == :per_test
      assert envelope.degraded

      assert envelope.meta[:unhooked_modules] == [UnhookedTest] or
               envelope.meta["unhooked_modules"] == [UnhookedTest]

      hooked = find_record(envelope.payload, "path_a")
      assert hooked, "missing hooked path_a record: #{inspect(envelope.payload)}"
      assert is_list(hooked.lines_hit) and hooked.lines_hit != []
    end
  end

  describe "seeded exclusive attribution (boundary hook)" do
    @tag :integration
    @tag spec: [
           "specled.coverage_capture.per_test_exclusive_attribution",
           "specled.coverage_capture.boundary_row_exclusive",
           "specled.coverage_capture.boundary_hook_sync",
           "specled.coverage_capture.case_template"
         ]
    test "hooked tests get disjoint, self-confined records across three explicit seeds" do
      # Deterministic exclusivity: two tests (hooked via SpecLedEx.Case) call
      # disjoint fixture functions. Tail snapshots run inside exec_on_exit
      # before the next test starts, so no seed can bleed coverage between
      # hooked windows. Would fail if Formatter.flush/1 ignored boundary rows
      # or if run_per_test/2 failed to arm the boundary table.
      seeds = [1, 42, 99]

      Enum.each(seeds, fn seed ->
        root = scaffold_exclusive_fixture()
        on_exit(fn -> File.rm_rf!(root) end)

        {path_a_lines, path_b_lines} = exclusive_function_lines(root)

        {output, status} =
          run_fixture_mix_test(root, [
            "spec.cover.test",
            "--per-test",
            "--seed",
            Integer.to_string(seed)
          ])

        assert status == 0,
               "expected exclusive fixture to pass under seed #{seed}, got #{status}.\nOutput:\n#{output}"

        artifact = Path.join(root, ".spec/_coverage/per_test.coverdata")
        assert File.exists?(artifact), "expected artifact under seed #{seed}. Output:\n#{output}"

        assert {:ok, envelope} = Store.read_v2(artifact)
        assert envelope.mode == :per_test
        assert envelope.meta[:boundary] == true or envelope.meta["boundary"] == true

        records = envelope.payload
        assert is_list(records) and records != []

        rec_a = find_record(records, "path_a")
        rec_b = find_record(records, "path_b")

        assert rec_a, "missing path_a record under seed #{seed}: #{inspect(records)}"
        assert rec_b, "missing path_b record under seed #{seed}: #{inspect(records)}"

        lines_a = MapSet.new(rec_a.lines_hit)
        lines_b = MapSet.new(rec_b.lines_hit)

        assert MapSet.size(lines_a) > 0, "path_a had no hits under seed #{seed}"
        assert MapSet.size(lines_b) > 0, "path_b had no hits under seed #{seed}"

        assert MapSet.disjoint?(lines_a, lines_b),
               "would fail if hooked tests' windows bled under seed #{seed}: " <>
                 "a=#{inspect(MapSet.to_list(lines_a))} b=#{inspect(MapSet.to_list(lines_b))}"

        assert MapSet.subset?(lines_a, path_a_lines),
               "path_a hits escaped own function lines under seed #{seed}: " <>
                 "#{inspect(MapSet.to_list(lines_a))} not subset of #{inspect(MapSet.to_list(path_a_lines))}"

        assert MapSet.subset?(lines_b, path_b_lines),
               "path_b hits escaped own function lines under seed #{seed}: " <>
                 "#{inspect(MapSet.to_list(lines_b))} not subset of #{inspect(MapSet.to_list(path_b_lines))}"
      end)
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
      plain_counts = decode_coverdata(plain_coverdata)
      per_test_counts = decode_coverdata(per_test_coverdata)

      assert plain_counts != [],
             "plain coverdata decoded to no call counts — the parity assertion below " <>
               "would pass vacuously on two empty decodes"

      assert Enum.any?(plain_counts, fn {{mod, _line}, _count} -> mod == Covered end),
             "expected decoded totals to include the fixture's Covered module"

      assert plain_counts == per_test_counts,
             "would fail if arming the --per-test formatter (native or classic snapshot " <>
               "reads layered on top of the same :cover-instrumented modules) perturbed the " <>
               "cumulative totals `mix test --cover` exports on its own"
    end
  end

  # Decodes a `.coverdata` file's per-module, per-line call counts in a
  # child BEAM (fresh `:cover` server + `:cover.import/1`), for comparing
  # two exports' actual coverage content rather than their raw bytes.
  # Runs out-of-process because a host-BEAM `:cover.stop/0` tears down the
  # coverage coordinator an outer `mix test --cover` run of this very suite
  # depends on — the same quarantine discipline as `run_fixture_mix_test/2`.
  # Mirrors `SpecLedEx.Coverage.Aggregate`'s `:cover.modules/0` +
  # `:cover.imported_modules/0` union: imported-only data (no local
  # cover-compile in that process) only shows up under `imported_modules/0`.
  @decode_begin "DECODE_COVERDATA_BEGIN"
  @decode_end "DECODE_COVERDATA_END"

  defp decode_coverdata(path) do
    script = """
    [path] = System.argv()
    {:ok, _pid} = :cover.start()
    :ok = :cover.import(String.to_charlist(path))

    result =
      (:cover.modules() ++ :cover.imported_modules())
      |> Enum.uniq()
      |> Enum.flat_map(fn mod ->
        case :cover.analyse(mod, :calls, :line) do
          {:ok, entries} -> entries
          _ -> []
        end
      end)
      |> Enum.sort()

    encoded = result |> :erlang.term_to_binary() |> Base.encode64()
    IO.write(["#{@decode_begin}", encoded, "#{@decode_end}"])
    """

    {output, status} = System.cmd("elixir", ["-e", script, path], stderr_to_stdout: true)

    assert status == 0,
           "expected child-BEAM coverdata decode of #{path} to exit 0, got #{status}.\nOutput:\n#{output}"

    assert output =~ @decode_begin and output =~ @decode_end,
           "child decode exited 0 but produced no output markers.\nOutput:\n#{output}"

    [_before, rest] = String.split(output, @decode_begin, parts: 2)
    [encoded, _after] = String.split(rest, @decode_end, parts: 2)

    encoded |> Base.decode64!() |> :erlang.binary_to_term()
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

  # One hooked (SpecLedEx.Case) + one unhooked bare ExUnit.Case module.
  defp scaffold_partial_hook_fixture do
    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_partial_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "lib", "covered.ex"]), exclusive_lib_module())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(
      Path.join([base, "test", "hooked_test.exs"]),
      """
      defmodule HookedTest do
        use SpecLedEx.Case, async: false

        test "path_a" do
          assert Covered.path_a() == 3
        end
      end
      """
    )

    File.write!(
      Path.join([base, "test", "unhooked_test.exs"]),
      """
      defmodule UnhookedTest do
        use ExUnit.Case, async: false

        test "path_b" do
          assert Covered.path_b() == 30
        end
      end
      """
    )

    base
  end

  # Two-test fixture hooked via SpecLedEx.Case; tests call disjoint functions.
  defp scaffold_exclusive_fixture(opts \\ []) do
    base =
      System.tmp_dir!()
      |> Path.join("specled_cover_exclusive_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base, "lib"))
    File.mkdir_p!(Path.join(base, "test"))

    File.write!(Path.join(base, "mix.exs"), mix_exs())
    File.write!(Path.join([base, "lib", "covered.ex"]), exclusive_lib_module())
    File.write!(Path.join([base, "test", "test_helper.exs"]), "ExUnit.start()\n")

    File.write!(
      Path.join([base, "test", "exclusive_test.exs"]),
      exclusive_test_module(Keyword.get(opts, :failing?, false))
    )

    base
  end

  defp exclusive_lib_module do
    """
    defmodule Covered do
      def path_a do
        x = 1
        y = 2
        x + y
      end

      def path_b do
        a = 10
        b = 20
        a + b
      end
    end
    """
  end

  defp exclusive_test_module(failing?) do
    path_a_expected = if failing?, do: 4, else: 3

    """
    defmodule ExclusiveTest do
      use SpecLedEx.Case, async: false

      test "path_a" do
        assert Covered.path_a() == #{path_a_expected}
      end

      test "path_b" do
        assert Covered.path_b() == 30
      end
    end
    """
  end

  defp exclusive_function_lines(root) do
    source = File.read!(Path.join([root, "lib", "covered.ex"]))
    lines = String.split(source, "\n")

    path_a = function_body_lines(lines, "path_a")
    path_b = function_body_lines(lines, "path_b")
    {path_a, path_b}
  end

  defp function_body_lines(lines, fun_name) do
    start =
      Enum.find_index(lines, &String.contains?(&1, "def #{fun_name}")) ||
        raise "function #{fun_name} not found"

    # Inclusive range from the def line through the matching end (1-indexed for cover).
    rest = Enum.drop(lines, start)
    depth = 0

    end_offset =
      Enum.find_index(rest, fn line ->
        cond do
          String.match?(line, ~r/\bdef\b/) ->
            # keep going; depth tracking via end only for this simple shape
            false

          String.trim(line) == "end" and depth == 0 ->
            true

          true ->
            false
        end
      end)

    # Simple shape: def ... end at column 2. Count lines from def through end.
    end_offset =
      end_offset ||
        Enum.find_index(rest, &(String.trim(&1) == "end"))

    Range.new(start + 1, start + end_offset + 1)
    |> MapSet.new()
  end

  defp find_record(records, fragment) do
    Enum.find(records, fn rec ->
      is_binary(rec.test_id) and String.contains?(rec.test_id, fragment)
    end)
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
