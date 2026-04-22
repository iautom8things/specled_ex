defmodule Mix.Tasks.Spec.Cover.Test do
  @shortdoc "Runs `mix test --cover` serialized, capturing per-test coverage"

  @moduledoc """
  Wraps `mix test --cover` for per-test coverage capture.

  Forces `Application.put_env(:ex_unit, :async, false)` and
  `ExUnit.configure(async: false)` before any test module is loaded, then
  installs `SpecLedEx.Coverage.Formatter` as an additional ExUnit formatter so
  per-test snapshots accumulate into `.spec/_coverage/per_test.coverdata`.

  Per ADR `specled.decision.serialized_per_test_coverage`, async-safe
  per-test attribution is not attempted: any test module that opts in to
  `async: true` is reported as a user bug. On exit the task prints a warning
  to stderr listing every test file that contains the literal pragma
  `async: true`.

  `mix test --cover` continues to work in its traditional cumulative mode;
  only this task produces the per-test artifact.

  ## Usage

      mix spec.cover.test
      mix spec.cover.test test/some/file_test.exs

  Any extra arguments pass through to `mix test --cover`.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    Application.put_env(:ex_unit, :async, false)
    Application.ensure_all_started(:ex_unit)
    ExUnit.configure(async: false)

    # Ensure the formatter module is resident before ExUnit boots its
    # formatter GenServers; in a child BEAM (fixture run) the parent app's
    # ebin must already be on the code path for this to succeed.
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.Formatter)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage.Store)
    {:module, _} = Code.ensure_loaded(SpecLedEx.Coverage)

    install_formatter()

    async_files = scan_async_true_test_files()

    try do
      Mix.Task.run("test", ["--cover" | argv])
    after
      warn_about_async_true(async_files)
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

  defp warn_about_async_true([]), do: :ok

  defp warn_about_async_true(files) do
    IO.puts(
      :stderr,
      "[spec.cover.test] WARNING: the following test files set `async: true` " <>
        "during a serialized per-test coverage run:\n" <>
        Enum.map_join(files, "\n", &("  - " <> &1))
    )
  end
end
