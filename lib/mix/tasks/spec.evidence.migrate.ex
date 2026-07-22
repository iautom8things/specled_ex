defmodule Mix.Tasks.Spec.Evidence.Migrate do
  use Mix.Task

  @requirements ["app.config"]

  alias SpecLedEx.Evidence.{Git, Store, TreeHash}
  alias SpecLedEx.Json
  alias SpecLedEx.Realization.HashStore

  @shortdoc "Migrates legacy state.json evidence into the orphan evidence store"
  @moduledoc """
  Performs the one-shot evidence split migration for an adopted repository.

  The migration hoists any legacy embedded realization baseline, untracks
  `.spec/state.json` while preserving the worktree file, appends it to
  `.gitignore`, installs the static pre-push hook, and runs a fresh
  `mix spec.check` when the post-migration tree has not already been seeded in
  the local orphan evidence ref.
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [root: :string, spec_dir: :string], aliases: [r: :root])

    SpecLedEx.TaskArgs.validate!("spec.evidence.migrate", rest, invalid)

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)

    hoist_legacy_realization(root, spec_dir)
    untrack_state_json(root, spec_dir)
    ensure_gitignore_entry(root)
    Mix.Tasks.Spec.Evidence.InstallHook.run(["--root", root])
    seed_evidence_unless_present(root, spec_dir)

    Mix.shell().info("spec.evidence.migrate complete")
  end

  @doc false
  def hoist_legacy_realization(root, spec_dir \\ ".spec") do
    state_path = Path.join(expand_spec_dir(root, spec_dir), "state.json")
    baseline = Path.join(root, HashStore.baseline_rel())

    if File.exists?(state_path) and not File.exists?(baseline) do
      case Json.read(state_path) do
        %{"realization" => %{} = realization} when map_size(realization) > 0 ->
          HashStore.merge(root, realization)
          Mix.shell().info("hoisted legacy realization baseline")

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp untrack_state_json(root, spec_dir) do
    rel = Path.join(spec_dir, "state.json")

    case Git.run(root, ["rm", "--cached", "--quiet", "--", rel]) do
      {:ok, _output} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp ensure_gitignore_entry(root) do
    path = Path.join(root, ".gitignore")
    existing = if File.exists?(path), do: File.read!(path), else: ""

    unless gitignore_has_state_json?(existing) do
      prefix = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(path, existing <> prefix <> ".spec/state.json\n")
    end
  end

  defp seed_evidence_unless_present(root, spec_dir) do
    case TreeHash.current(root) do
      {:ok, tree_hash} ->
        case Store.read(root, tree_hash) do
          {:ok, _entry} ->
            Mix.shell().info("spec evidence already seeded for current tree")

          _ ->
            Mix.Tasks.Spec.Check.run(["--root", root, "--spec-dir", spec_dir])
        end

      {:error, reason} ->
        Mix.raise("Unable to compute current tree for evidence migration: #{inspect(reason)}")
    end
  end

  defp gitignore_has_state_json?(contents) do
    contents
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == ".spec/state.json"))
  end

  defp expand_spec_dir(root, spec_dir) do
    if Path.type(spec_dir) == :absolute do
      spec_dir
    else
      Path.join(root, spec_dir)
    end
  end
end
