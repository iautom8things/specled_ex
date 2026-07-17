defmodule Mix.Tasks.Spec.Prune do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Explicitly prunes unreachable spec-evidence entries"
  @moduledoc """
  Explicitly removes evidence entries whose tree hashes are not reachable from
  local branch heads or remote-tracking refs, then lease-pushes the result.

  Do not prune during active review windows: reviewers may still depend on
  evidence for commits that are temporarily unreachable from retained refs.

  ## Options

    * `--root <path>` — repository root (default: cwd)
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} = OptionParser.parse(args, strict: [root: :string], aliases: [r: :root])
    validate_args!(rest, invalid)
    root = opts[:root] || File.cwd!()

    with {:ok, _fetched} <- SpecLedEx.Evidence.Sync.fetch(root),
         {:ok, keep} <- reachable_tree_hashes(root),
         {:ok, result} <- SpecLedEx.Evidence.Sync.run(root, keep: keep) do
      Mix.shell().info(
        "spec-evidence pruned and synced as of last fetch: ahead=#{result.ahead} behind=#{result.behind}"
      )

      :ok
    else
      {:error, reason} -> Mix.raise("evidence/prune_failed: #{inspect(reason)}")
    end
  end

  defp reachable_tree_hashes(root) do
    with {:ok, refs_output} <-
           git(root, [
             "for-each-ref",
             "--format=%(refname)",
             "refs/heads",
             "refs/remotes"
           ]) do
      refs =
        refs_output
        |> String.split("\n", trim: true)
        |> Enum.reject(&evidence_ref?/1)

      case refs do
        [] ->
          {:ok, MapSet.new()}

        refs ->
          case git(root, ["log", "--format=%T" | refs]) do
            {:ok, output} -> {:ok, output |> String.split("\n", trim: true) |> MapSet.new()}
            error -> error
          end
      end
    end
  end

  defp evidence_ref?(ref) do
    ref == "refs/heads/spec-evidence" or String.ends_with?(ref, "/spec-evidence")
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    details =
      Enum.map(invalid, fn {flag, _value} -> flag end)
      |> Kernel.++(Enum.map(rest, &inspect/1))
      |> Enum.join(", ")

    Mix.raise("Invalid arguments for spec.prune: #{details}")
  end

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, args, output, status}}
    end
  end
end
