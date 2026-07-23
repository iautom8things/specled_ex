defmodule Mix.Tasks.Spec.Cover.Ingest do
  @shortdoc "Ingests a .coverdata file into a v2 spec coverage envelope"

  @moduledoc """
  CI / coveralls escape hatch: ingests any exported `.coverdata` file (for
  example one already produced by `mix test --cover --export-coverage NAME`
  for coveralls reporting) into the versioned v2 spec coverage envelope, so
  specled coverage is available for free from an existing coverage export
  without a second serialized test run.

  Delegates ingestion to `SpecLedEx.Coverage.Aggregate.ingest/2` and persists
  the resulting envelope via `SpecLedEx.Coverage.Store.write_v2/2`.

  ## Usage

      mix spec.cover.ingest path/to/file.coverdata
      mix spec.cover.ingest path/to/file.coverdata --output .spec/_coverage/per_test.coverdata

  Exits non-zero with a clear message when the given path is missing, is
  not a valid `.coverdata` file, or decodes to zero cover-compiled modules
  (`{:error, :empty_coverage}`).
  """

  use Mix.Task

  # Intentionally no `@requirements ["app.config"]`: like spec.cover.test,
  # this task is exercised inside child-BEAM test fixtures
  # (test_support/specled_ex_integration_case.ex) that load the parent's
  # spec_led_ex ebin via SPECLED_EX_EBIN. Mix's `app.config` rewrites the
  # code path to declared deps only, evicting the parent ebin before
  # `run/1` can lazily load SpecLedEx.MixRuntime.

  alias SpecLedEx.Coverage.{Aggregate, Store}

  @impl Mix.Task
  def run(argv) do
    SpecLedEx.MixRuntime.ensure_started!()
    Mix.Task.run("loadpaths", ["--no-deps-check"])

    {opts, args} = OptionParser.parse!(argv, strict: [output: :string])

    case args do
      [coverdata_path] ->
        do_ingest(coverdata_path, opts[:output] || Store.default_path())

      _ ->
        Mix.raise("usage: mix spec.cover.ingest <path/to/file.coverdata> [--output PATH]")
    end
  end

  defp do_ingest(coverdata_path, output) do
    case Aggregate.ingest(coverdata_path, source: coverdata_path) do
      {:ok, envelope} ->
        write_envelope(envelope, output)

      {:error, :not_found} ->
        Mix.raise("no such file: #{coverdata_path}")

      {:error, :empty_coverage} ->
        # Still record a refusal via Store.write_v2/2 (an empty envelope
        # refuses with `{:error, :empty_files}`) so `Store.read_status/1`
        # on `output` reports `{:refused, ...}` rather than leaving no
        # sidecar at all — indistinguishable from "never ran".
        empty_envelope =
          Store.build_envelope(%{
            mode: :aggregate,
            source: coverdata_path,
            files: [],
            mfas: [],
            degraded: true,
            payload: %{unmapped_modules: 0}
          })

        {:error, :empty_files} = Store.write_v2(empty_envelope, output)
        Mix.raise("#{coverdata_path} carries no cover-compiled modules (empty coverage)")

      {:error, {:import_failed, reason}} ->
        Mix.raise("failed to import #{coverdata_path}: #{inspect(reason)}")
    end
  end

  defp write_envelope(envelope, output) do
    case Store.write_v2(envelope, output) do
      :ok ->
        degraded_note = if envelope.degraded, do: ", degraded", else: ""

        Mix.shell().info(
          "Wrote #{output} (#{length(envelope.files)} files, #{length(envelope.mfas)} mfas" <>
            degraded_note <> ")"
        )

      {:error, :empty_files} ->
        Mix.raise(
          "ingest produced an envelope with no file coverage; refusing to write #{output}"
        )
    end
  end
end
