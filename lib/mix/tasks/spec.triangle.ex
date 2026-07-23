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

  Reads the v2 coverage envelope (`SpecLedEx.Coverage.Store.read_v2/1`) and
  prints its `mode` (`aggregate` or `per_test`). In `:aggregate` mode each
  requirement additionally prints `closure_coverage: K/N MFAs executed
  (X.X%)` from `SpecLedEx.CoverageTriangulation.aggregate_requirement_reach/2`,
  and the per-test-only detectors (`branch_guard_untethered_test`, the
  per-test form of `branch_guard_underspecified_realization`, and
  `reaching_tests`) are labeled `detector_unavailable` (reason
  `aggregate_artifact_only`) rather than silently omitted. A missing,
  legacy (pre-v2), invalid, or async-contaminated per-test artifact each
  print their own distinct `detector_unavailable` note.

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
    envelope_result = load_envelope(artifact_path)
    edges = load_tracer_edges()
    tag_index = tag_index_from_index(index)

    subjects = normalized_subjects(index)
    world = %{subjects: subjects, tracer_edges: edges}

    selected_subjects
    |> Enum.map(fn subject ->
      build_diagnostic(subject, subjects, world, envelope_result, tag_index)
    end)
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

  # covers: specled.triangulation.envelope_legacy_and_invalid_distinct
  # Mirrors SpecLedEx.Review.CoverageClosure's private load_envelope/1 —
  # existence is checked before decoding so a genuinely-missing artifact
  # reports :no_coverage_artifact rather than Store.read_v2/1's
  # :invalid_artifact (which covers "present but undecodable").
  defp load_envelope(path) do
    if File.regular?(path) do
      case Store.read_v2(path) do
        {:ok, envelope} -> {:ok, envelope}
        {:error, :legacy_artifact, _message} -> {:degraded, :legacy_artifact}
        {:error, :invalid_artifact} -> {:degraded, :invalid_artifact}
      end
    else
      {:degraded, :no_coverage_artifact}
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

  defp build_diagnostic(subject, subjects, world, envelope_result, tag_index) do
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

    coverage = resolve_coverage(envelope_result, subject_id, closure_map, requirements, tag_index)

    %{
      subject_id: subject_id,
      surface: normalized.surface,
      impl_bindings: normalized.impl_bindings,
      closure_available?: closure != nil,
      coverage_available?: coverage.available?,
      mode: coverage.mode,
      degraded_reason: coverage.degraded_reason,
      requirements: coverage.requirements,
      execution_reach: coverage.execution_reach,
      coverage_records_count: coverage.records_count,
      detector_unavailable_notes: coverage.detector_unavailable_notes
    }
  end

  # covers: specled.triangulation.spec_triangle_task
  # Resolves the loaded v2 envelope (or one of the three degraded statuses
  # Store.read_v2/1 distinguishes, mirrored by load_envelope/1 above) into
  # the fields render/1 prints. :aggregate mode computes per-requirement
  # closure-coverage % via CoverageTriangulation.aggregate_requirement_reach/2
  # and labels the per-test-only detectors detector_unavailable via
  # CoverageTriangulation.envelope_findings/3 (reason aggregate_artifact_only)
  # rather than silently omitting them. :per_test mode reuses the v1
  # execution-reach diagnostic unchanged (the envelope's :payload IS the v1
  # record list) unless the envelope itself is degraded (async
  # contamination), which is labeled detector_unavailable instead of
  # computing per-test findings over data that may be corrupted.
  defp resolve_coverage(
         {:degraded, status},
         _subject_id,
         closure_map,
         requirements,
         tag_index
       )
       when status in [:no_coverage_artifact, :legacy_artifact, :invalid_artifact] do
    notes =
      status
      |> CoverageTriangulation.envelope_findings(closure_map, tag_index)
      |> Enum.map(&detector_unavailable_note/1)

    %{
      available?: false,
      mode: nil,
      degraded_reason: status,
      requirements: requirements,
      execution_reach: "n/a (#{status})",
      records_count: 0,
      detector_unavailable_notes: notes
    }
  end

  defp resolve_coverage(
         {:ok, %{mode: :per_test, degraded: true} = envelope},
         _subject_id,
         closure_map,
         requirements,
         tag_index
       ) do
    notes =
      envelope
      |> CoverageTriangulation.envelope_findings(closure_map, tag_index)
      |> Enum.map(&detector_unavailable_note/1)

    %{
      available?: false,
      mode: :per_test,
      degraded_reason: :async_contaminated,
      requirements: requirements,
      execution_reach: "n/a (per-test coverage degraded)",
      records_count: 0,
      detector_unavailable_notes: notes
    }
  end

  defp resolve_coverage(
         {:ok, %{mode: :per_test, payload: records}},
         subject_id,
         closure_map,
         requirements,
         _tag_index
       ) do
    reach = CoverageTriangulation.execution_reach_map(records, closure_map)

    %{
      available?: true,
      mode: :per_test,
      degraded_reason: nil,
      requirements: requirements,
      execution_reach: Map.get(reach, subject_id, "n/a"),
      records_count: length(records),
      detector_unavailable_notes: []
    }
  end

  defp resolve_coverage(
         {:ok, %{mode: :aggregate} = envelope},
         subject_id,
         closure_map,
         requirements,
         tag_index
       ) do
    reach = CoverageTriangulation.aggregate_requirement_reach(envelope, closure_map)

    annotated =
      Enum.map(requirements, fn req ->
        case Map.get(reach, {subject_id, req.id}) do
          nil -> req
          r -> Map.put(req, :closure_coverage, r)
        end
      end)

    notes =
      envelope
      |> CoverageTriangulation.envelope_findings(closure_map, tag_index)
      |> Enum.filter(&(&1["code"] == "detector_unavailable"))
      |> Enum.map(&detector_unavailable_note/1)

    %{
      available?: true,
      mode: :aggregate,
      degraded_reason: nil,
      requirements: annotated,
      execution_reach:
        "n/a (aggregate mode has no per-subject execution_reach; see per-requirement closure_coverage)",
      records_count: length(envelope.mfas),
      detector_unavailable_notes: notes
    }
  end

  defp detector_unavailable_note(finding), do: "#{finding["reason"]} — #{finding["message"]}"

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

    if d.mode, do: Mix.shell().info("mode: #{d.mode}")

    if not d.closure_available?,
      do: Mix.shell().info("note: tracer manifest missing; closure walk skipped")

    render_degraded_note(d.degraded_reason)

    Enum.each(d.detector_unavailable_notes, fn note ->
      Mix.shell().info("detector_unavailable: #{note}")
    end)

    Mix.shell().info("")

    Enum.each(d.requirements, fn req ->
      Mix.shell().info("- #{req.id}")
      Mix.shell().info("  effective_binding: #{inspect(req.effective_binding)}")

      Mix.shell().info("  closure_mfas: #{format_list(req.closure_mfas)}")

      Mix.shell().info("  closure_files: #{format_list(req.closure_files)}")

      Mix.shell().info("  exercising_tests: #{format_list(req.exercising_tests)}")

      render_closure_coverage(Map.get(req, :closure_coverage))
    end)
  end

  # Preserves the exact pre-v2 wording for the missing-artifact case (tests
  # assert on it); legacy/invalid/async-contaminated are new distinct notes.
  defp render_degraded_note(:no_coverage_artifact),
    do: Mix.shell().info("note: coverage artifact missing; run `mix spec.cover.test`")

  defp render_degraded_note(:legacy_artifact),
    do:
      Mix.shell().info(
        "note: coverage artifact is a legacy (pre-v2) format; run `mix spec.cover.test` to regenerate it"
      )

  defp render_degraded_note(:invalid_artifact),
    do:
      Mix.shell().info(
        "note: coverage artifact is invalid or undecodable; run `mix spec.cover.test` to regenerate it"
      )

  defp render_degraded_note(:async_contaminated),
    do:
      Mix.shell().info(
        "note: per-test coverage is degraded (async contamination); re-run `mix spec.cover.test --per-test` without --allow-async"
      )

  defp render_degraded_note(nil), do: :ok

  defp render_closure_coverage(nil), do: :ok

  defp render_closure_coverage(reach) do
    Mix.shell().info(
      "  closure_coverage: #{reach.executed_mfa_count}/#{reach.closure_mfa_count} MFAs executed (#{format_pct(reach.line_coverage_pct)})"
    )
  end

  defp format_pct(pct) when is_float(pct), do: "#{:erlang.float_to_binary(pct, decimals: 1)}%"
  defp format_pct(_), do: "0.0%"

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
