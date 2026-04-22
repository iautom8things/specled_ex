defmodule Mix.Tasks.Spec.SuggestBinding do
  use Mix.Task

  @shortdoc "Prints proposed realized_by: blocks for subjects with no binding"
  @moduledoc """
  Prints a proposed `realized_by:` block for every subject that has no
  `realized_by` field yet. Proposals are derived from the subject's
  `spec-meta.surface` entries — `.ex` files under `lib/` are proposed as
  `api_boundary` module bindings. The task is **proposal-only**: it does NOT
  accept `--write`. Agents apply proposals through their own editing tools.

  ## Options

    * `--root <path>` — project root (default: cwd)
    * `--fail-on-missing` — exit non-zero when any subject lacks a binding

  ## Why no `--write`?

  See `specled.api_boundary.suggest_binding_proposal_only`. Writing into spec
  files requires surgical edits inside fenced `spec-meta` YAML that LLM agents
  already handle well; adding a CLI writer would bifurcate the edit path and
  hide diffs from review.
  """

  @impl Mix.Task
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(
        args,
        strict: [root: :string, fail_on_missing: :boolean],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()
    fail_on_missing? = Keyword.get(opts, :fail_on_missing, false)

    spec_dir = SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    index = SpecLedEx.index(root, spec_dir: spec_dir, authored_dir: authored_dir)

    subjects =
      index
      |> Map.get("subjects", [])
      |> List.wrap()

    missing = Enum.filter(subjects, &missing_binding?/1)

    Enum.each(missing, fn subject ->
      Mix.shell().info(render_proposal(subject))
    end)

    if missing == [] do
      Mix.shell().info("All subjects have realized_by bindings.")
    end

    if fail_on_missing? and missing != [] do
      Mix.raise("#{length(missing)} subject(s) missing realized_by bindings")
    end

    :ok
  end

  defp missing_binding?(subject) do
    case subject["meta"] do
      %{realized_by: rb} when is_map(rb) and map_size(rb) > 0 -> false
      %{realized_by: _} -> true
      _ -> true
    end
  end

  defp render_proposal(subject) do
    id = subject_id(subject)
    surface = surface_list(subject)

    lib_modules =
      surface
      |> Enum.filter(&String.starts_with?(&1, "lib/"))
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.map(&file_to_module_name/1)

    lines =
      [
        "# Proposed realized_by for subject #{id}",
        "# Apply inside the spec-meta block:",
        "realized_by:",
        "  api_boundary:"
      ] ++
        if lib_modules == [] do
          ["    # No lib/*.ex surface entries found; populate manually."]
        else
          Enum.map(lib_modules, fn mod -> "    - \"#{mod}\"" end)
        end

    Enum.join(lines, "\n") <> "\n"
  end

  defp subject_id(subject) do
    case subject["meta"] do
      %{id: id} when is_binary(id) -> id
      %{"id" => id} -> id
      _ -> subject["file"] || "<unknown>"
    end
  end

  defp surface_list(subject) do
    case subject["meta"] do
      %{surface: list} when is_list(list) -> list
      %{"surface" => list} when is_list(list) -> list
      _ -> []
    end
  end

  defp file_to_module_name(path) do
    path
    |> Path.rootname(".ex")
    |> String.replace_prefix("lib/", "")
    |> String.split("/")
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join(".")
  end
end
