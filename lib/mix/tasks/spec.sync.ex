defmodule Mix.Tasks.Spec.Sync do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Reconciles the local and remote spec-evidence ledger"
  @moduledoc """
  Fetches and reconciles `spec-evidence` by a content-based tree union, then
  pushes with a lease pinned to the fetched remote tip.

  ## Options

    * `--root <path>` — repository root (default: cwd)
    * `--best-effort` — warn once and return successfully if sync fails
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [root: :string, best_effort: :boolean],
        aliases: [r: :root]
      )

    validate_args!(rest, invalid)
    root = opts[:root] || File.cwd!()

    case SpecLedEx.Evidence.Sync.run(root) do
      {:ok, result} ->
        Mix.shell().info(
          "spec-evidence drift as of last fetch: ahead=#{result.ahead} behind=#{result.behind}"
        )

        print_warnings(result.warnings)

        :ok

      {:error, reason} ->
        message = "evidence/sync_failed: #{inspect(reason)}"

        if opts[:best_effort] do
          Mix.shell().error("warning: #{message}")
          :ok
        else
          Mix.raise(message)
        end
    end
  end

  defp print_warnings(warnings) do
    Enum.each(warnings, fn warning -> Mix.shell().error(warning.message) end)
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    details =
      Enum.map(invalid, fn {flag, _value} -> flag end)
      |> Kernel.++(Enum.map(rest, &inspect/1))
      |> Enum.join(", ")

    Mix.raise("Invalid arguments for spec.sync: #{details}")
  end
end
