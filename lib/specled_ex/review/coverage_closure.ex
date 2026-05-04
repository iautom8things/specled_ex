defmodule SpecLedEx.Review.CoverageClosure do
  # covers: specled.spec_review.coverage_tab_bind_closure
  @moduledoc """
  Computes per-requirement bind-closure reach data for the spec.review HTML
  Coverage tab.

  The pipeline mirrors `mix spec.triangle`:

    1. Load the tracer manifest (callee edges) — without it the closure
       walk cannot run and the Coverage tab degrades to a "binding closure
       unavailable" message.
    2. Walk the implementation closure for each subject via
       `SpecLedEx.Realization.Closure.compute/2`.
    3. Load `.spec/_coverage/per_test.coverdata` via
       `SpecLedEx.Coverage.Store`. Missing artifact → degrade to a
       "coverage artifact unavailable" message that piggybacks the
       `:degraded` leg state machinery (see
       `specled.spec_review.degraded_leg_state`).
    4. Hand both into `SpecLedEx.CoverageTriangulation.per_requirement_reach/2`
       which returns the per-requirement reach summary the renderer turns
       into "Closure: N MFAs. Reached: M (by tests T1, T2). Unreached: K."

  The function is read-only: missing artifacts produce a status atom rather
  than raising, so spec.review keeps rendering even when triangulation
  inputs are absent (the same posture used by spec.triangle).
  """

  alias SpecLedEx.Compiler.Tracer
  alias SpecLedEx.Coverage.Store
  alias SpecLedEx.CoverageTriangulation
  alias SpecLedEx.Realization.Closure

  @type reach_status :: :ok | :no_coverage_artifact | :no_tracer_manifest

  @type subject_reach :: %{
          status: reach_status(),
          by_requirement: %{optional(String.t()) => map()}
        }

  @doc """
  Returns `%{subject_id => subject_reach}` for every subject in `index`.

  Each `subject_reach` carries:

    * `:status` — `:ok` when both the tracer manifest and coverage
      artifact were loaded, `:no_tracer_manifest` when the tracer manifest
      is missing (closure walk skipped), `:no_coverage_artifact` when the
      manifest loaded but `.spec/_coverage/per_test.coverdata` is missing.
    * `:by_requirement` — `%{requirement_id => reach_map}` from
      `CoverageTriangulation.per_requirement_reach/2`. Empty when status
      is degraded.

  `opts` (all optional, primarily for tests):

    * `:tracer_edges` — pre-loaded tracer-edge map (skips disk read).
    * `:coverage_records` — pre-loaded coverage records OR
      `:no_coverage_artifact` (skips disk read).
    * `:artifact_path` — override `.spec/_coverage/per_test.coverdata`.
  """
  @spec build(map(), keyword()) :: %{optional(String.t()) => subject_reach()}
  def build(index, opts \\ []) when is_map(index) do
    tracer_edges =
      case Keyword.fetch(opts, :tracer_edges) do
        {:ok, edges} -> edges
        :error -> load_tracer_edges()
      end

    coverage_records =
      case Keyword.fetch(opts, :coverage_records) do
        {:ok, records} ->
          records

        :error ->
          path = Keyword.get(opts, :artifact_path) || Store.default_path()
          load_coverage(path)
      end

    subjects = normalized_subjects(index)

    cond do
      tracer_edges == %{} ->
        Map.new(subjects, fn s ->
          {s.id, %{status: :no_tracer_manifest, by_requirement: %{}}}
        end)

      coverage_records == :no_coverage_artifact ->
        Map.new(subjects, fn s ->
          {s.id, %{status: :no_coverage_artifact, by_requirement: %{}}}
        end)

      true ->
        world = %{subjects: subjects, tracer_edges: tracer_edges}

        Map.new(subjects, fn subject ->
          closure = Closure.compute(subject, world)

          requirements =
            requirements_for(index, subject.id)
            |> Enum.map(fn req -> requirement_view(req, closure) end)

          closure_map = %{
            subjects: %{
              subject.id => %{
                owned_files: subject.surface,
                requirements: requirements
              }
            }
          }

          per_req = CoverageTriangulation.per_requirement_reach(coverage_records, closure_map)

          by_req =
            case per_req do
              :no_coverage_artifact ->
                %{}

              map when is_map(map) ->
                Map.new(requirements, fn req ->
                  {req.id, Map.get(map, {subject.id, req.id}, empty_reach(req))}
                end)
            end

          {subject.id, %{status: :ok, by_requirement: by_req}}
        end)
    end
  end

  defp empty_reach(req) do
    %{
      closure_mfa_count: length(Map.get(req, :closure_mfas, [])),
      closure_file_count: req |> Map.get(:closure_files, []) |> Enum.uniq() |> length(),
      reached_files: [],
      unreached_files: req |> Map.get(:closure_files, []) |> Enum.uniq() |> Enum.sort(),
      reaching_tests: []
    }
  end

  # ---------------------------------------------------------------------------
  # Closure plumbing — mirrors mix spec.triangle so behavior stays consistent.
  # ---------------------------------------------------------------------------

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

  defp load_coverage(path) do
    if File.regular?(path) do
      Store.read(path)
    else
      :no_coverage_artifact
    end
  end

  defp normalized_subjects(index) do
    index
    |> Map.get("subjects", [])
    |> Enum.map(fn subject ->
      meta = fetch_field(subject, "meta")
      id = fetch_field(meta, "id")

      surface =
        meta
        |> fetch_field("surface")
        |> List.wrap()
        |> Enum.filter(&is_binary/1)

      impl =
        meta
        |> fetch_field("realized_by")
        |> case do
          %{} = rb -> rb
          _ -> %{}
        end
        |> normalize_keys()
        |> Map.get("implementation", [])
        |> List.wrap()

      %{id: id || "<unknown>", surface: surface, impl_bindings: impl}
    end)
    |> Enum.reject(&(&1.id == "<unknown>"))
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp requirements_for(index, subject_id) do
    index
    |> Map.get("subjects", [])
    |> Enum.find(fn s ->
      meta = fetch_field(s, "meta")
      fetch_field(meta, "id") == subject_id
    end)
    |> case do
      nil -> []
      subject -> subject |> fetch_field("requirements") |> List.wrap() |> Enum.filter(&is_map/1)
    end
  end

  defp requirement_view(req, closure) do
    req_id = fetch_field(req, "id")

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

    %{
      id: req_id,
      binding_present?: closure_files != [],
      closure_files: closure_files,
      closure_mfas: Enum.map(closure_mfa_tuples, &mfa_to_string/1)
    }
  end

  defp mfa_to_string({mod, fun, arity}), do: "#{inspect(mod)}.#{fun}/#{arity}"
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
end
