defmodule Mix.Tasks.Spec.Cover.Test do
  @shortdoc "Runs mix test --cover, aggregate-ingesting coverage by default"

  @moduledoc """
  Default mode: runs `mix test --cover --export-coverage specled` with no
  custom formatter and no async configuration changes, then, guarded by the
  existence of the exported `.coverdata` file, ingests it via
  `SpecLedEx.Coverage.Aggregate.ingest/2` and persists the resulting v2
  envelope via `SpecLedEx.Coverage.Store.write_v2/2` at
  `SpecLedEx.Coverage.Store.default_path/0`.

  The task's exit code passes through the underlying `mix test` suite
  status (a red suite still exits non-zero even though its exported
  coverage — if any — is still ingested; that coverage is real, not a
  placeholder). After a suite that ran to completion, an ingestion refusal
  or empty coverage (zero cover-compiled modules) additionally forces a
  non-zero exit naming the refusal reason.

  Per Decision 2 (epic specled_-155), this task keeps its name even though
  its default behavior is no longer the old serialized per-test capture:
  that flow moved behind the opt-in `--per-test` flag below. The prior
  default (forcing `ExUnit.configure(async: false)` globally) never actually
  serialized modules that themselves declared `async: true` — an explicit
  per-module `async: true` overrides the global default — so it was an
  overclaim for aggregate coverage, which does not need per-test isolation
  in the first place. `mix test --cover` itself continues to work in its
  traditional cumulative mode.

  ## --per-test (opt-in serialized per-test capture)

      mix spec.cover.test --per-test
      mix spec.cover.test --per-test --allow-async

  Forces `Application.put_env(:ex_unit, :async, false)` and
  `ExUnit.configure(async: false)` before any test module loads, then installs
  `SpecLedEx.Coverage.Formatter` (armed via the `:specled_ex, :spec_cover_run`
  seam — see its moduledoc) as an additional ExUnit formatter so per-test
  snapshots accumulate into `.spec/_coverage/per_test.coverdata`.

  Per-test `:cover` attribution has no per-pid surface: a test file that
  declares `async: true` runs concurrently regardless of the global
  `ExUnit.configure(async: false)` default (see above), which genuinely
  corrupts serialized per-test snapshots. Per
  `specled.decision.serialized_per_test_coverage`, this is treated as a user
  bug: the task exits non-zero, naming every test file containing the literal
  pragma `async: true`, before running the suite. Pass `--allow-async` to
  degrade instead of failing: the suite still runs and the task still exits
  0, but stderr carries a warning naming the contaminated files (their
  per-test records may be unreliable).

  ## Usage

      mix spec.cover.test
      mix spec.cover.test test/some/file_test.exs
      mix spec.cover.test --per-test
      mix spec.cover.test --per-test --allow-async

  Any extra arguments pass through to `mix test`.
  """

  use Mix.Task

  # Intentionally no `@requirements ["app.config"]`: this task is invoked inside
  # child-BEAM test fixtures (test_support/specled_ex_integration_case.ex) that
  # load the parent's spec_led_ex ebin via SPECLED_EX_EBIN. Mix's `app.config`
  # rewrites the code path to declared deps only, evicting the parent ebin
  # before `run/1` can lazily load SpecLedEx.MixRuntime.

  alias SpecLedEx.Coverage.{Aggregate, Store}

  @export_name "specled"

  @impl Mix.Task
  def run(argv) do
    SpecLedEx.MixRuntime.ensure_started!()

    {per_test?, argv} = pop_flag(argv, "--per-test")
    {allow_async?, argv} = pop_flag(argv, "--allow-async")

    if per_test? do
      run_per_test(argv, allow_async?)
    else
      run_aggregate(argv)
    end
  end

  # ---------------------------------------------------------------------
  # Default mode: plain `mix test --cover --export-coverage`, aggregate
  # ingest guarded by coverdata existence.
  # ---------------------------------------------------------------------

  defp run_aggregate(argv) do
    coverdata_path = Path.join(cover_output_dir(), "#{@export_name}.coverdata")

    # Ensure the ingestion modules are resident before `mix test` runs: in a
    # child BEAM (fixture run), that nested task's own loadpaths pass
    # rewrites the code path to the fixture's own declared deps, which would
    # otherwise evict the parent's lazily-loaded ebin before ingestion needs
    # it.
    {:module, _} = Code.ensure_loaded(Aggregate)
    {:module, _} = Code.ensure_loaded(Store)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.MfaKey)

    try do
      Mix.Task.run("test", ["--cover", "--export-coverage", @export_name | argv])
    after
      ingest_if_present(coverdata_path)
    end
  end

  defp cover_output_dir do
    Mix.Project.config()
    |> Keyword.get(:test_coverage, [])
    |> Keyword.get(:output, "cover")
  end

  defp ingest_if_present(coverdata_path) do
    if File.regular?(coverdata_path) do
      ingest(coverdata_path)
    else
      :ok
    end
  end

  defp ingest(coverdata_path) do
    case Aggregate.ingest(coverdata_path, source: coverdata_path) do
      {:ok, envelope} ->
        write_envelope(envelope)

      {:error, :empty_coverage} ->
        refuse_empty_coverage(coverdata_path)

      {:error, {:import_failed, reason}} ->
        Mix.raise("mix spec.cover.test: failed to import #{coverdata_path}: #{inspect(reason)}")
    end
  end

  defp write_envelope(envelope) do
    case Store.write_v2(envelope, Store.default_path()) do
      :ok ->
        degraded_note = if envelope.degraded, do: ", degraded", else: ""

        Mix.shell().info(
          "mix spec.cover.test: ingested #{length(envelope.files)} files, " <>
            "#{length(envelope.mfas)} mfas#{degraded_note} into #{Store.default_path()}"
        )

      {:error, :empty_files} ->
        Mix.raise(
          "mix spec.cover.test: ingested coverage carries no file data; refusing to write " <>
            Store.default_path()
        )
    end
  end

  defp refuse_empty_coverage(coverdata_path) do
    empty_envelope =
      Store.build_envelope(%{
        mode: :aggregate,
        source: coverdata_path,
        files: [],
        mfas: [],
        degraded: true,
        payload: %{unmapped_modules: 0}
      })

    {:error, :empty_files} = Store.write_v2(empty_envelope, Store.default_path())

    Mix.raise(
      "mix spec.cover.test: #{coverdata_path} carries no cover-compiled modules " <>
        "(empty coverage)"
    )
  end

  # ---------------------------------------------------------------------
  # --per-test: opt-in serialized formatter-driven capture (old default).
  # ---------------------------------------------------------------------

  defp run_per_test(argv, allow_async?) do
    async_files = scan_async_true_test_files()

    if async_files != [] and not allow_async? do
      Mix.raise(contamination_message(async_files))
    end

    Application.put_env(:ex_unit, :async, false)
    Application.ensure_all_started(:ex_unit)
    ExUnit.configure(async: false)

    # Arms SpecLedEx.Coverage.Formatter -- see its moduledoc. Without this,
    # installing it below is inert.
    Application.put_env(:specled_ex, :spec_cover_run, true)

    # Ensure the formatter module is resident before ExUnit boots its
    # formatter GenServers; in a child BEAM (fixture run) the parent app's
    # ebin must already be on the code path for this to succeed.
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.Formatter)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.Store)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.Snapshot)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage)

    install_formatter()

    try do
      Mix.Task.run("test", ["--cover" | argv])
    after
      if async_files != [] do
        warn_about_async_true(async_files)
      end
    end
  end

  defp install_formatter do
    existing = Application.get_env(:ex_unit, :formatters, [ExUnit.CLIFormatter])

    formatters =
      if SpecLedEx.Coverage.Formatter in existing do
        existing
      else
        existing ++ [SpecLedEx.Coverage.Formatter]
      end

    ExUnit.configure(formatters: formatters)
  end

  defp scan_async_true_test_files do
    "test/**/*_test.exs"
    |> Path.wildcard()
    |> Enum.filter(&contains_async_true?/1)
    |> Enum.sort()
  end

  defp contains_async_true?(path) do
    case File.read(path) do
      {:ok, content} -> Regex.match?(~r/async:\s*true/, content)
      _ -> false
    end
  end

  defp contamination_message(files) do
    "[spec.cover.test --per-test] the following test files set `async: true`, " <>
      "which corrupts serialized per-test :cover attribution:\n" <>
      Enum.map_join(files, "\n", &("  - " <> &1)) <>
      "\nPass --allow-async to run anyway with a degraded (unreliable for those tests) capture."
  end

  defp warn_about_async_true(files) do
    IO.puts(
      :stderr,
      "[spec.cover.test --per-test] WARNING: degraded run -- the following test files set " <>
        "`async: true` during a serialized per-test coverage run; their per-test " <>
        "attribution may be unreliable:\n" <>
        Enum.map_join(files, "\n", &("  - " <> &1))
    )
  end

  defp pop_flag(argv, flag) do
    if flag in argv do
      {true, List.delete(argv, flag)}
    else
      {false, argv}
    end
  end
end
