defmodule Mix.Tasks.Spec.Check do
  use Mix.Task

  alias SpecLedEx.VerificationStrength

  @shortdoc "Runs spec.plan and strict spec.verify"
  @moduledoc """
  Runs `mix spec.plan` followed by strict `mix spec.verify`.

  `mix spec.check` enables command execution by default. Use `--no-run-commands`
  to keep command verifications structural-only for a given run.

  ## Options

    * `--no-run-commands` - skip executing `kind: command` verifications
    * `--min-strength claimed|linked|executed` - require a minimum verification strength
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          root: :string,
          output: :string,
          spec_dir: :string,
          debug: :boolean,
          run_commands: :boolean,
          min_strength: :string
        ],
        aliases: [r: :root, o: :output, d: :debug]
      )

    validate_args!(rest, invalid)
    validate_min_strength!(opts[:min_strength])

    shared_args = option_args(opts, [:root, :output, :spec_dir])
    verify_args =
      shared_args ++
        option_args(opts, [:debug, :min_strength]) ++ run_command_args(opts) ++ ["--strict"]

    Mix.Task.run("spec.plan", shared_args)
    Mix.Task.run("spec.verify", verify_args)
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for spec.check: #{details}")
  end

  defp option_args(opts, keys) do
    Enum.flat_map(keys, fn key ->
      case Keyword.fetch(opts, key) do
        {:ok, true} -> ["--#{option_name(key)}"]
        {:ok, false} -> []
        {:ok, value} -> ["--#{option_name(key)}", value]
        :error -> []
      end
    end)
  end

  defp run_command_args(opts) do
    case Keyword.fetch(opts, :run_commands) do
      {:ok, true} -> ["--run-commands"]
      {:ok, false} -> ["--no-run-commands"]
      :error -> ["--run-commands"]
    end
  end

  defp option_name(key) do
    key
    |> Atom.to_string()
    |> String.replace("_", "-")
  end

  defp validate_min_strength!(nil), do: nil

  defp validate_min_strength!(value) do
    case VerificationStrength.normalize(value) do
      {:ok, normalized} ->
        normalized

      {:error, message} ->
        Mix.raise("Invalid value for --min-strength: #{message}")
    end
  end
end
