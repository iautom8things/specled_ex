defmodule Mix.Tasks.Spec.DedupRealizedBy do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Prints proposed realized_by: dedup edits removing api_boundary lines already implied by implementation"
  @moduledoc """
  Prints proposed YAML edits that remove every `api_boundary` line whose entry
  also appears under `implementation` for the same subject. Per
  `specled.decision.realized_by_tier_implication`, the implication
  `implementation` ⟹ `api_boundary` makes the explicit `api_boundary` listing
  redundant: agents should drop it, and this task renders the removal for
  agent-side application.

  Each proposal block is grouped by subject and includes a
  `# already implied by implementation` comment on the removed line so the
  diff is self-documenting (per
  `specled.tasks.dedup_realized_by_proposal`).

  ## Options

    * `--root <path>` — project root (default: cwd)
    * `--fail-on-dups` — exit non-zero whenever any subject has duplicates

  ## Why no `--write`?

  See `specled.tasks.dedup_realized_by_no_write`. This task is a proposal
  renderer only; agents apply edits via their own tooling, mirroring the
  contract of `mix spec.suggest_binding`. Writing into spec files requires
  surgical edits inside fenced `spec-meta` YAML that LLM agents already
  handle well; adding a CLI writer would bifurcate the edit path and hide
  diffs from review.

  ## Shared duplicate-detection seam

  The duplicate set is computed via
  `SpecLedEx.Validator.RealizedByDedupe.duplicates/1`, the same helper used
  by the `mix spec.validate` `realized_by_redundant_dup` warning, so the
  proposal output and the validator finding cannot disagree (per
  `specled.tasks.dedup_realized_by_shared_seam`).
  """

  alias SpecLedEx.Validator.RealizedByDedupe

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, _rest, _invalid} =
      OptionParser.parse(
        args,
        strict: [root: :string, fail_on_dups: :boolean],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()
    fail_on_dups? = Keyword.get(opts, :fail_on_dups, false)

    spec_dir = SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    index = SpecLedEx.index(root, spec_dir: spec_dir, authored_dir: authored_dir)

    subjects =
      index
      |> Map.get("subjects", [])
      |> List.wrap()

    subjects_with_dups =
      subjects
      |> Enum.map(fn subject -> {subject, RealizedByDedupe.duplicates(subject)} end)
      |> Enum.reject(fn {_subject, dups} -> dups == [] end)
      |> Enum.sort_by(fn {subject, _dups} -> subject_id(subject) end)

    Enum.each(subjects_with_dups, fn {subject, dups} ->
      Mix.shell().info(render_proposal(subject, dups))
    end)

    if subjects_with_dups == [] do
      Mix.shell().info("No realized_by duplications found.")
    end

    if fail_on_dups? and subjects_with_dups != [] do
      Mix.raise(
        "#{length(subjects_with_dups)} subject(s) have realized_by duplications"
      )
    end

    :ok
  end

  defp render_proposal(subject, dups) do
    id = subject_id(subject)

    entries =
      dups
      |> Enum.map(fn {_tier_pair, entry} -> entry end)
      |> Enum.uniq()
      |> Enum.sort()

    lines =
      [
        "# Proposed realized_by dedup for subject #{id}",
        "# Apply inside the spec-meta block; remove these api_boundary lines:",
        "realized_by:",
        "  api_boundary:"
      ] ++
        Enum.map(entries, fn entry ->
          "    - \"#{entry}\" # already implied by implementation"
        end)

    Enum.join(lines, "\n") <> "\n"
  end

  defp subject_id(subject) when is_map(subject) do
    case Map.get(subject, "meta") || Map.get(subject, :meta) do
      nil ->
        Map.get(subject, "file") || "<unknown>"

      meta ->
        case meta_id(meta) do
          nil -> Map.get(subject, "file") || "<unknown>"
          id -> id
        end
    end
  end

  defp subject_id(_), do: "<unknown>"

  defp meta_id(meta) when is_map(meta) do
    Map.get(meta, :id) || Map.get(meta, "id")
  end

  defp meta_id(_), do: nil
end
