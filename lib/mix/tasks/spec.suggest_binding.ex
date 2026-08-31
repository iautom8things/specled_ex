defmodule Mix.Tasks.Spec.SuggestBinding do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Prints proposed realized_by: blocks for subjects with no binding"
  @moduledoc """
  Prints a proposed `realized_by:` block for every subject that has no
  `realized_by` field yet. Proposals are derived from the subject's
  `spec-meta.surface` entries — `.ex` files under `lib/` are proposed as
  `api_boundary` module bindings.

  Each `lib/*.ex` surface file is read and its top-level `defmodule` name(s)
  are resolved from the source AST, so acronyms and namespace segments that a
  naive path camelization would mangle (e.g. `LLMExtractor`, or
  `ExampleWeb.TerminalChannel` from `lib/example_web/channels/...`) are
  proposed correctly. When a surface file is absent or unparseable, the task
  falls back to the path-derived name so proposals are still produced for
  not-yet-written files.

  The task is **proposal-only**: it does NOT accept `--write`. Agents apply
  proposals through their own editing tools.

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
    SpecLedEx.MixRuntime.ensure_started!()

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
      Mix.shell().info(render_proposal(subject, root))
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

  defp render_proposal(subject, root) do
    id = subject_id(subject)
    surface = surface_list(subject)

    lib_modules =
      surface
      |> Enum.filter(&String.starts_with?(&1, "lib/"))
      |> Enum.filter(&String.ends_with?(&1, ".ex"))
      |> Enum.flat_map(&file_to_module_names(root, &1))
      |> Enum.uniq()

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

  # Resolve the module name(s) a surface file actually defines by reading its
  # source AST. Falls back to the path-derived name when the file is missing or
  # unparseable, so proposals are still produced for not-yet-written files.
  #
  # Path camelization alone is wrong for any module whose name does not match a
  # naive camelize of its path — acronyms (`LLMExtractor`, not `LlmExtractor`),
  # namespace segments absent from the path (`ExotermWeb.TerminalChannel` from
  # `lib/exoterm_web/channels/terminal_channel.ex`), or `defmodule` aliasing.
  defp file_to_module_names(root, path) do
    full = Path.join(root, path)

    with {:ok, source} <- File.read(full),
         {:ok, ast} <- Code.string_to_quoted(source),
         [_ | _] = mods <- top_level_defmodule_names(ast) do
      mods
    else
      _ -> [path_to_module_name(path)]
    end
  end

  defp top_level_defmodule_names(ast) do
    ast
    |> top_level_forms()
    |> Enum.flat_map(fn
      {:defmodule, _meta, [{:__aliases__, _, parts}, _body]} when is_list(parts) ->
        if Enum.all?(parts, &is_atom/1) do
          [Enum.map_join(parts, ".", &Atom.to_string/1)]
        else
          []
        end

      _other ->
        []
    end)
  end

  defp top_level_forms({:__block__, _meta, forms}) when is_list(forms), do: forms
  defp top_level_forms(form), do: [form]

  defp path_to_module_name(path) do
    path
    |> Path.rootname(".ex")
    |> String.replace_prefix("lib/", "")
    |> String.split("/")
    |> Enum.flat_map(&String.split(&1, "."))
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join(".")
  end
end
