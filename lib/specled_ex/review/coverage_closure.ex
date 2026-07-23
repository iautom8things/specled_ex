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
  alias SpecLedEx.Coverage.{MfaKey, Store}
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

  defp mfa_to_string({mod, fun, arity}), do: MfaKey.format({mod, fun, arity})
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

  # ---------------------------------------------------------------------------
  # v2 envelope path (epic specled_-155, T6)
  #
  # `build/2` above is the v1 path used today by `SpecLedEx.Review.build_view/3`
  # — untouched, so review.ex/html.ex (T7's rendering migration, out of scope
  # here) keep working exactly as before.
  #
  # `build_v2/2` below is the additive v2 counterpart: it reads
  # `SpecLedEx.Coverage.Store.read_v2/1` instead of `Store.read/1` and adds
  # per-requirement MFA-level closure coverage plus tagged-test evidence
  # strength. It is not wired into `Review.build_view/3` yet — that wiring is
  # T7's job.
  # ---------------------------------------------------------------------------

  @type v2_status ::
          :ok_aggregate
          | :ok_per_test
          | :no_coverage_artifact
          | :legacy_artifact
          | :invalid_artifact
          | :no_tracer_manifest
          | :async_contaminated

  @type v2_tagged_test :: %{file: String.t(), test_name: String.t(), strength: String.t()}

  @type v2_requirement_reach :: %{
          closure_mfa_count: non_neg_integer(),
          closure_coverage_pct: float() | :no_closure_mfas,
          covered_mfas: [String.t()],
          uncovered_mfas: [String.t()],
          tagged_tests: [v2_tagged_test()],
          self_verified?: boolean()
        }

  @type v2_subject_reach :: %{
          status: v2_status(),
          by_requirement: %{optional(String.t()) => v2_requirement_reach()}
        }

  @doc """
  Envelope-based counterpart to `build/2`.

  Returns `%{subject_id => v2_subject_reach()}` for every subject in `index`,
  reading the v2 coverage envelope (`SpecLedEx.Coverage.Store.read_v2/1`)
  instead of the v1 record list.

  Each subject's `:status` is one of:

    * `:ok_aggregate` / `:ok_per_test` — envelope loaded; mode-tagged so
      renderers can distinguish observed, race-bounded per-test attribution
      (`:ok_per_test`) — itself currently a file-level proxy rather than true
      per-test MFA data (specled_-jjq) — from cumulative MFA-level coverage
      (`:ok_aggregate`); neither is exact (specled_-cpw).
    * `:no_coverage_artifact` — no artifact on disk.
    * `:legacy_artifact` — the artifact decodes as a pre-v2 (v1) list; per
      Decision 5, never auto-migrated.
    * `:invalid_artifact` — the artifact exists but is undecodable/malformed.
      Distinct from `:no_coverage_artifact` and `:legacy_artifact` — none of
      the three collapse into a silent empty-but-ok result.
    * `:no_tracer_manifest` — the compiler tracer manifest is missing, so the
      closure walk itself could not run (checked first, same precedence as
      `build/2`).
    * `:async_contaminated` — the envelope loaded as `:per_test` but carries
      `degraded: true` (the `--per-test` lane's async-contamination guard,
      the same condition `CoverageTriangulation.envelope_findings/3` reports
      under reason `:async_contaminated`). `by_requirement` is empty rather
      than reporting untrustworthy per-test attribution as `:ok_per_test` —
      see the flag-1 addendum on specled_-155.7.

  Each `by_requirement` entry carries:

    * `:closure_mfa_count` / `:covered_mfas` / `:uncovered_mfas` — the
      requirement's closure MFAs (via `SpecLedEx.Coverage.MfaKey`),
      partitioned by coverage.
    * `:closure_coverage_pct` — `covered / total * 100`, or the atom
      `:no_closure_mfas` when the closure has zero MFAs. This is a
      deliberately distinct value from `0.0`: a requirement with no closure
      at all (no binding, or a binding that resolves to nothing) is a
      different problem than a requirement whose closure exists and is
      simply untested, and the two must not render identically as "0%".
    * `:tagged_tests` — every test carrying `@tag spec:` for this
      requirement, each with an evidence `:strength` (`"claimed"`,
      `"linked"`, or `"executed"` — `SpecLedEx.VerificationStrength`'s
      vocabulary). Aggregate coverage has no per-test attribution, so a
      tagged test can only ever reach `"linked"` (tag exists, and the
      envelope confirms *some* execution) or `"claimed"` (tag exists, zero
      confirmed execution) under `:ok_aggregate`; `"executed"` (a specific
      tagged test's own coverage record reached the closure) is only
      reachable under `:ok_per_test`.
    * `:self_verified?` — `closure_coverage_pct` is a positive number AND at
      least one tagged test reached `"executed"` strength. Per the epic's
      design, this composite is only ever true under `:ok_per_test` —
      aggregate coverage's `"linked"` ceiling means it can never satisfy the
      `"executed"` half on its own.

  `opts` (all optional):

    * `:tracer_edges` — pre-loaded tracer-edge map (skips disk read).
    * `:envelope` — pre-loaded envelope, or one of `:no_coverage_artifact`,
      `:legacy_artifact`, `:invalid_artifact` (skips disk read).
    * `:tag_index` — pre-built `%{spec: %{requirement_id => [tag_entry]}}`
      (skips reading `index["test_tags"]`).
    * `:artifact_path` — override `.spec/_coverage/per_test.coverdata`.
  """
  @spec build_v2(map(), keyword()) :: %{optional(String.t()) => v2_subject_reach()}
  def build_v2(index, opts \\ []) when is_map(index) do
    tracer_edges =
      case Keyword.fetch(opts, :tracer_edges) do
        {:ok, edges} -> edges
        :error -> load_tracer_edges()
      end

    subjects = normalized_subjects(index)

    if tracer_edges == %{} do
      Map.new(subjects, fn s -> {s.id, %{status: :no_tracer_manifest, by_requirement: %{}}} end)
    else
      artifact_path = Keyword.get(opts, :artifact_path) || Store.default_path()
      tag_index = v2_tag_index(index, opts)

      case resolve_envelope(opts, artifact_path) do
        {:degraded, status} ->
          Map.new(subjects, fn s -> {s.id, %{status: status, by_requirement: %{}}} end)

        # covers: specled.spec_review.coverage_tab_v2_envelope_data_layer
        # Flag 1 (specled_-155.7 orchestrator addendum): build_v2 previously
        # tagged a degraded `:per_test` envelope `:ok_per_test` with no
        # render-visible signal that per-test attribution may be corrupted
        # by async contamination. Neither `:status` nor `:by_requirement`
        # carried any other channel for this, so the renderer could not
        # detect it without this minimal status special-case — a distinct
        # `:async_contaminated` status, empty `by_requirement` (same shape
        # as the other degraded statuses above).
        {:ok, %{mode: :per_test, degraded: true}} ->
          Map.new(subjects, fn s ->
            {s.id, %{status: :async_contaminated, by_requirement: %{}}}
          end)

        {:ok, envelope} ->
          world = %{subjects: subjects, tracer_edges: tracer_edges}
          status = if envelope.mode == :aggregate, do: :ok_aggregate, else: :ok_per_test

          Map.new(subjects, fn subject ->
            closure = Closure.compute(subject, world)

            requirements =
              requirements_for(index, subject.id)
              |> Enum.map(fn req -> requirement_view(req, closure) end)

            closure_map = %{
              subjects: %{
                subject.id => %{owned_files: subject.surface, requirements: requirements}
              }
            }

            by_req =
              v2_by_requirement(envelope, closure_map, subject.id, requirements, tag_index)

            {subject.id, %{status: status, by_requirement: by_req}}
          end)
      end
    end
  end

  defp resolve_envelope(opts, path) do
    case Keyword.fetch(opts, :envelope) do
      {:ok, atom} when atom in [:no_coverage_artifact, :legacy_artifact, :invalid_artifact] ->
        {:degraded, atom}

      {:ok, %{} = envelope} ->
        {:ok, envelope}

      :error ->
        load_envelope(path)
    end
  end

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

  defp v2_tag_index(index, opts) do
    case Keyword.fetch(opts, :tag_index) do
      {:ok, tag_index} ->
        tag_index

      :error ->
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
  end

  defp v2_by_requirement(
         %{mode: :aggregate} = envelope,
         closure_map,
         subject_id,
         requirements,
         tag_index
       ) do
    reach = CoverageTriangulation.aggregate_requirement_reach(envelope, closure_map)
    spec_tags = Map.get(tag_index, :spec, %{})

    Map.new(requirements, fn req ->
      r =
        Map.get(reach, {subject_id, req.id}, %{
          closure_mfa_count: 0,
          executed_mfa_count: 0,
          covered_mfas: [],
          uncovered_mfas: []
        })

      tagged_tests =
        spec_tags
        |> Map.get(req.id, [])
        |> Enum.map(fn entry ->
          strength = if r.executed_mfa_count > 0, do: "linked", else: "claimed"

          %{
            file: Map.get(entry, :file, ""),
            test_name: Map.get(entry, :test_name, ""),
            strength: strength
          }
        end)

      {req.id, v2_requirement_entry(r, tagged_tests)}
    end)
  end

  defp v2_by_requirement(
         %{mode: :per_test} = envelope,
         closure_map,
         subject_id,
         requirements,
         tag_index
       ) do
    per_req = CoverageTriangulation.per_requirement_reach(envelope.payload, closure_map)
    spec_tags = Map.get(tag_index, :spec, %{})

    Map.new(requirements, fn req ->
      per_req_entry =
        Map.get(per_req, {subject_id, req.id}, %{reached_files: [], reaching_tests: []})

      reached_files = MapSet.new(per_req_entry.reached_files, &normalize_path/1)
      reaching_tests = MapSet.new(per_req_entry.reaching_tests)

      closure_mfas = req |> Map.get(:closure_mfas, []) |> Enum.uniq()

      # Per-test v1 records carry file-level `lines_hit`, not MFA-level
      # coverage — there is no per-test equivalent of the aggregate
      # envelope's per-MFA `:covered` flag (that lands with T5's per-test
      # lane rebuild). Until then this reuses the same static
      # MFA->source-file mapping `requirement_view/2` used to build
      # `closure_files`, at per-MFA granularity, and calls an MFA "covered"
      # when its own source file was reached by some test.
      {covered, uncovered} =
        Enum.split_with(closure_mfas, fn mfa_str ->
          case MfaKey.parse(mfa_str) do
            {:ok, mfa_tuple} ->
              mfa_tuple
              |> mfa_source_file()
              |> Enum.any?(&MapSet.member?(reached_files, normalize_path(&1)))

            _ ->
              false
          end
        end)

      r = %{
        closure_mfa_count: length(closure_mfas),
        executed_mfa_count: length(covered),
        covered_mfas: Enum.sort(covered),
        uncovered_mfas: Enum.sort(uncovered)
      }

      tagged_tests =
        spec_tags
        |> Map.get(req.id, [])
        |> Enum.map(fn entry ->
          display = "#{Map.get(entry, :file, "")} :: #{Map.get(entry, :test_name, "")}"
          strength = if MapSet.member?(reaching_tests, display), do: "executed", else: "linked"

          %{
            file: Map.get(entry, :file, ""),
            test_name: Map.get(entry, :test_name, ""),
            strength: strength
          }
        end)

      {req.id, v2_requirement_entry(r, tagged_tests)}
    end)
  end

  defp v2_requirement_entry(r, tagged_tests) do
    closure_coverage_pct =
      if r.closure_mfa_count == 0 do
        :no_closure_mfas
      else
        Float.round(r.executed_mfa_count / r.closure_mfa_count * 100, 2)
      end

    self_verified? =
      is_float(closure_coverage_pct) and closure_coverage_pct > 0.0 and
        Enum.any?(tagged_tests, &(&1.strength == "executed"))

    %{
      closure_mfa_count: r.closure_mfa_count,
      closure_coverage_pct: closure_coverage_pct,
      covered_mfas: r.covered_mfas,
      uncovered_mfas: r.uncovered_mfas,
      tagged_tests: tagged_tests,
      self_verified?: self_verified?
    }
  end

  defp normalize_path(path) when is_binary(path), do: String.trim_leading(path, "./")
  defp normalize_path(other), do: other
end
