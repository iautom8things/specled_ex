defmodule Mix.Tasks.Spec.Triangle do
  # covers: specled.triangulation.spec_triangle_task
  use Mix.Task

  @requirements ["app.config"]

  alias SpecLedEx.Compiler.Tracer
  alias SpecLedEx.Coverage.Store
  alias SpecLedEx.CoverageTriangulation
  alias SpecLedEx.Realization.{Closure, EffectiveBinding}

  @shortdoc "Prints per-requirement triangulation diagnostics for specs"
  @moduledoc """
  Read-only triangulation diagnostic.

      mix spec.triangle
      mix spec.triangle --all
      mix spec.triangle <subject.id>

  With no subject id, or with `--all`, prints diagnostics for every indexed
  subject. With a subject id, prints diagnostics for that subject only.

  For every requirement on each selected subject, prints:

    * the effective `realized_by` binding (merged subject+requirement),
    * the closure MFAs reached from the declared `implementation` binding,
    * the per-test coverage records whose files intersect that closure, and
    * the subject's execution-reach ratio rendered as `"N/M (0.FF)"`.

  Artifacts that are absent degrade gracefully: the task prints a note and
  continues rather than failing. This task never mutates `state.json` (per
  `specled.triangulation.spec_triangle_task`).
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [root: :string, spec_dir: :string, artifact_path: :string, all: :boolean]
      )

    selection = parse_selection!(opts, rest, invalid)

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)

    # index/2 is a pure build — it does not write state.json.
    index = SpecLedEx.index(root, spec_dir: spec_dir, authored_dir: authored_dir)

    selected_subjects = select_subjects!(index, selection)

    artifact_path = opts[:artifact_path] || Store.default_path()
    coverage = load_coverage(artifact_path)
    edges = load_tracer_edges()
    tag_index = tag_index_from_index(index)

    subjects = normalized_subjects(index)
    world = %{subjects: subjects, tracer_edges: edges}

    selected_subjects
    |> Enum.map(fn subject -> build_diagnostic(subject, subjects, world, coverage, tag_index) end)
    |> render_all()
  end

  defp parse_selection!(_opts, rest, invalid) when invalid != [] do
    usage!(invalid, rest)
  end

  defp parse_selection!(opts, rest, _invalid) do
    case {Keyword.get(opts, :all, false), rest} do
      {true, []} ->
        :all

      {false, []} ->
        :all

      {false, [id]} when is_binary(id) and id != "" ->
        {:subject, id}

      _ ->
        usage!([], rest)
    end
  end

  defp usage!(invalid, rest) do
    Mix.raise(
      "Usage: mix spec.triangle [--all | <subject.id>] " <>
        "(invalid: #{inspect(invalid)} rest: #{inspect(rest)})"
    )
  end

  # ---------------------------------------------------------------------------
  # Artifact loading
  # ---------------------------------------------------------------------------

  defp load_coverage(path) do
    if File.regular?(path) do
      {:ok, Store.read(path)}
    else
      :missing
    end
  end

  defp load_tracer_edges do
    path = Tracer.manifest_path()

    with true <- File.regular?(path),
         {:ok, binary} <- File.read(path),
         map when is_map(map) <- :erlang.binary_to_term(binary) do
      map
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp tag_index_from_index(index) do
    raw_tags = Map.get(index, "test_tags") || %{}

    spec =
      Map.new(raw_tags, fn {req_id, entries} ->
        {req_id,
         Enum.map(entries, fn e ->
           %{
             file: Map.get(e, "file") || Map.get(e, :file) || "",
             test_name: Map.get(e, "test_name") || Map.get(e, :test_name) || ""
           }
         end)}
      end)

    %{spec: spec, opt_out: []}
  end

  # ---------------------------------------------------------------------------
  # Subject normalization
  # ---------------------------------------------------------------------------

  defp find_subject(index, subject_id) do
    index
    |> Map.get("subjects", [])
    |> Enum.find(fn subject ->
      subject_id_of(subject) == subject_id
    end)
  end

  defp select_subjects!(index, :all) do
    index
    |> Map.get("subjects", [])
    |> Enum.filter(&(subject_id_of(&1) != nil))
  end

  defp select_subjects!(index, {:subject, subject_id}) do
    case find_subject(index, subject_id) do
      nil -> Mix.raise("Unknown subject: #{subject_id}")
      subject -> [subject]
    end
  end

  defp subject_id_of(subject) do
    subject
    |> meta()
    |> fetch_field("id")
    |> case do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp fetch_field(map, key) when is_map(map) and is_binary(key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key, if(atom_key, do: Map.get(map, atom_key)))
  end

  defp fetch_field(_, _), do: nil

  defp normalized_subjects(index) do
    index
    |> Map.get("subjects", [])
    |> Enum.map(fn subject ->
      impl =
        subject
        |> meta_realized_by()
        |> Map.get("implementation", [])

      %{
        id: subject_id_of(subject) || "<unknown>",
        surface:
          meta(subject) |> fetch_field("surface") |> List.wrap() |> Enum.filter(&is_binary/1),
        impl_bindings: impl
      }
    end)
    |> Enum.reject(&(&1.id == "<unknown>"))
  end

  defp meta(subject) when is_map(subject) do
    case fetch_field(subject, "meta") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp meta_realized_by(subject) do
    case fetch_field(meta(subject), "realized_by") do
      %{} = rb -> normalize_keys(rb)
      _ -> %{}
    end
  end

  defp normalize_keys(rb) do
    Map.new(rb, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  # ---------------------------------------------------------------------------
  # Diagnostic assembly
  # ---------------------------------------------------------------------------

  defp build_diagnostic(subject, subjects, world, coverage, tag_index) do
    subject_id = subject_id_of(subject)

    normalized =
      Enum.find(subjects, fn s -> s.id == subject_id end) ||
        %{id: subject_id, surface: [], impl_bindings: []}

    closure = if world.tracer_edges != %{}, do: Closure.compute(normalized, world), else: nil

    requirements =
      subject
      |> fetch_field("requirements")
      |> List.wrap()
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn req -> build_requirement_view(subject, req, closure, tag_index) end)

    closure_map =
      closure_map_from_requirements(subject_id, normalized.surface, requirements)

    reach =
      case coverage do
        {:ok, records} -> CoverageTriangulation.execution_reach_map(records, closure_map)
        :missing -> %{subject_id => "n/a (coverage missing)"}
      end

    %{
      subject_id: subject_id,
      surface: normalized.surface,
      impl_bindings: normalized.impl_bindings,
      closure_available?: closure != nil,
      coverage_available?: coverage != :missing,
      requirements: requirements,
      execution_reach: Map.get(reach, subject_id, "n/a"),
      coverage_records_count: coverage_count(coverage)
    }
  end

  defp coverage_count({:ok, records}) when is_list(records), do: length(records)
  defp coverage_count(_), do: 0

  defp build_requirement_view(subject, req, closure, tag_index) do
    req_id = fetch_field(req, "id")
    effective_binding = EffectiveBinding.for_requirement(subject, req)

    closure_mfa_tuples =
      if closure do
        closure.owned_mfas ++ closure.shared_mfas
      else
        []
      end

    closure_files =
      closure_mfa_tuples
      |> Enum.flat_map(&mfa_source_file/1)
      |> Enum.uniq()

    exercising =
      tag_index.spec
      |> Map.get(req_id, [])
      |> Enum.map(fn entry -> "#{entry.file} :: #{entry.test_name}" end)

    %{
      id: req_id,
      effective_binding: effective_binding,
      closure_mfas: Enum.map(closure_mfa_tuples, &mfa_to_string/1),
      closure_files: closure_files,
      exercising_tests: exercising
    }
  end

  defp closure_map_from_requirements(subject_id, surface, requirements) do
    %{
      subjects: %{
        subject_id => %{
          owned_files: surface,
          requirements:
            Enum.map(requirements, fn req ->
              %{
                id: req.id,
                binding_present?: req.closure_files != [],
                closure_files: req.closure_files,
                closure_mfas: req.closure_mfas
              }
            end)
        }
      }
    }
  end

  defp mfa_to_string({mod, fun, arity}),
    do: "#{inspect(mod)}.#{fun}/#{arity}"

  defp mfa_to_string(other), do: to_string(other)

  defp mfa_source_file({mod, _fun, _arity}) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        case mod.module_info(:compile)[:source] do
          path when is_list(path) -> [List.to_string(path)]
          path when is_binary(path) -> [path]
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp render(d) do
    Mix.shell().info("subject: #{d.subject_id}")
    Mix.shell().info("surface: #{Enum.join(d.surface, ", ")}")

    Mix.shell().info("impl_bindings: #{Enum.join(d.impl_bindings, ", ")}")
    Mix.shell().info("execution_reach: #{d.execution_reach}")
    Mix.shell().info("coverage_records: #{d.coverage_records_count}")

    if not d.closure_available?,
      do: Mix.shell().info("note: tracer manifest missing; closure walk skipped")

    if not d.coverage_available?,
      do: Mix.shell().info("note: coverage artifact missing; run `mix spec.cover.test`")

    Mix.shell().info("")

    Enum.each(d.requirements, fn req ->
      Mix.shell().info("- #{req.id}")
      Mix.shell().info("  effective_binding: #{inspect(req.effective_binding)}")

      Mix.shell().info("  closure_mfas: #{format_list(req.closure_mfas)}")

      Mix.shell().info("  closure_files: #{format_list(req.closure_files)}")

      Mix.shell().info("  exercising_tests: #{format_list(req.exercising_tests)}")
    end)
  end

  defp render_all([]), do: Mix.shell().info("subjects: 0")

  defp render_all(diagnostics) do
    diagnostics
    |> Enum.with_index()
    |> Enum.each(fn {diagnostic, index} ->
      if index > 0, do: Mix.shell().info("")
      render(diagnostic)
    end)
  end

  defp format_list([]), do: "(none)"
  defp format_list(list), do: Enum.join(list, ", ")
end
