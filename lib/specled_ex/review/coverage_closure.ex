defmodule SpecLedEx.Review.CoverageClosure do
  # covers: specled.spec_review.coverage_tab_bind_closure
  @moduledoc """
  Computes per-requirement bind-closure reach data for the spec.review HTML
  Coverage tab, via `build_v2/2` (see its `@doc` for the envelope-based
  pipeline).

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

  Read-only: missing artifacts produce a status atom rather than raising, so
  spec.review keeps rendering even when triangulation inputs are absent (the
  same posture used by spec.triangle).
  """

  alias SpecLedEx.Compiler.Tracer
  alias SpecLedEx.Coverage.{MfaKey, MfaLines, Store}
  alias SpecLedEx.CoverageTriangulation
  alias SpecLedEx.Realization.Closure

  # ---------------------------------------------------------------------------
  # Closure plumbing — mirrors mix spec.triangle so behavior stays consistent.
  # ---------------------------------------------------------------------------

  defp load_tracer_edges do
    path = Tracer.manifest_path()

    with true <- File.regular?(path),
         {:ok, binary} <- File.read(path),
         # Not [:safe]: mirrors `Mix.Tasks.Spec.Triangle.load_tracer_edges/0`
         # (see its comment) — `Tracer` merges the manifest incrementally, so
         # a caller/callee module renamed or deleted since it was traced can
         # legitimately linger as a "ghost" entry whose atom this fresh BEAM
         # hasn't interned yet; read-time filtering, not decode, prunes it.
         map when is_map(map) <- :erlang.binary_to_term(binary) do
      map
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
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
      # MFA-based, not file-based: an out-of-repo compile source contributes
      # no closure file, but the binding still exists — the MFA-level
      # untested-realization gate reads this and must keep flagging it.
      binding_present?: closure_mfa_tuples != [],
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
          path when is_list(path) -> repo_relative_source(List.to_string(path))
          path when is_binary(path) -> repo_relative_source(path)
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  # Coverage-record `:file` values are repo-root-relative
  # (CoverageTriangulation.repo_relative_source_path/1); closure files must
  # carry the same identity or file-level joins against records can never
  # match. A source outside the repo root resolves to no file rather than an
  # absolute path no record can equal.
  defp repo_relative_source(path) do
    root = File.cwd!() |> Path.expand()
    absolute = Path.expand(path, root)

    if String.starts_with?(absolute, root <> "/") do
      [Path.relative_to(absolute, root)]
    else
      []
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

  # ---------------------------------------------------------------------------
  # v2 envelope path (epic specled_-155, T6)
  #
  # `build_v2/2` below reads the v2 coverage envelope
  # (`SpecLedEx.Coverage.Store.read_v2/1`) and adds per-requirement MFA-level
  # closure coverage plus tagged-test evidence strength. It is the sole path
  # wired into `SpecLedEx.Review.build_view/3` — the v1 record-list path this
  # comment used to describe was deleted once build_view switched over.
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
          no_debug_info_mfas: [String.t()],
          unresolvable_source_mfas: [String.t()],
          tagged_tests: [v2_tagged_test()],
          self_verified?: boolean()
        }

  @type v2_attribution :: :exact | :degraded_unhooked

  @type v2_subject_reach :: %{
          required(:status) => v2_status(),
          required(:by_requirement) => %{optional(String.t()) => v2_requirement_reach()},
          optional(:attribution) => v2_attribution(),
          optional(:unhooked_modules) => [module()]
        }

  @doc """
  Returns `%{subject_id => v2_subject_reach()}` for every subject in `index`,
  reading the v2 coverage envelope (`SpecLedEx.Coverage.Store.read_v2/1`).

  Each subject's `:status` is one of:

    * `:ok_aggregate` / `:ok_per_test` — envelope loaded; mode-tagged so
      renderers can distinguish real per-test MFA attribution
      (`:ok_per_test`, exact within disclosed chained windows when the
      envelope is non-degraded / fully hooked) from cumulative MFA-level coverage
      (`:ok_aggregate`). Under `:ok_per_test`, subject maps may also carry
      `:attribution` (`:exact` | `:degraded_unhooked`) and
      `:unhooked_modules` read from envelope `meta` (Stage 2).
    * `:no_coverage_artifact` — no artifact on disk.
    * `:legacy_artifact` — the artifact decodes as a pre-v2 (v1) list; per
      Decision 5, never auto-migrated.
    * `:invalid_artifact` — the artifact exists but is undecodable/malformed.
      Distinct from `:no_coverage_artifact` and `:legacy_artifact` — none of
      the three collapse into a silent empty-but-ok result.
    * `:no_tracer_manifest` — the compiler tracer manifest is missing, so the
      closure walk itself could not run (checked first, ahead of any
      envelope-loading status).
    * `:async_contaminated` — the envelope loaded as `:per_test` but carries
      `degraded: true` without an unhooked-modules meta signal (the
      `--per-test` lane's async-contamination guard, the same condition
      `CoverageTriangulation.envelope_findings/3` reports under reason
      `:async_contaminated`). `by_requirement` is empty rather than
      reporting untrustworthy per-test attribution as `:ok_per_test` —
      see the flag-1 addendum on specled_-155.7. Unhooked-only degradation
      (`meta.unhooked_modules` non-empty) stays on the `:ok_per_test` path
      with `:attribution => :degraded_unhooked` so hooked-window reach is
      still reported.

  Each `by_requirement` entry carries:

    * `:closure_mfa_count` / `:covered_mfas` / `:uncovered_mfas` — the
      requirement's closure MFAs (via `SpecLedEx.Coverage.MfaKey`),
      partitioned by coverage. Under `:ok_per_test`, coverage is true
      per-test line→MFA intersection via
      `CoverageTriangulation.per_test_requirement_reach/3` and
      `SpecLedEx.Coverage.MfaLines` — not a file-level proxy.
    * `:no_debug_info_mfas` — closure MFAs whose module has no abstract
      code; neither covered nor uncovered, surfaced as a distinct note.
    * `:unresolvable_source_mfas` — closure MFAs whose module index, MFA line
      entry, compile source, or MFA identity could not be resolved. They stay
      in the denominator and are surfaced separately from no-debug and
      ordinary uncovered MFAs.
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
    * `:line_index` — pre-built `MfaLines.index/1` result (skips indexing;
      tests use this to inject a stub without relying on fixture BEAM
      layout).
    * `:per_test_reach_fn` — test-only three-argument replacement for
      `CoverageTriangulation.per_test_requirement_reach/3`.
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
        # Flag 1 (specled_-155.7 orchestrator addendum): window-invalidating
        # degradation (`:async` contamination or `:counters_harvested` in
        # `meta.degraded_reasons`) collapses to :async_contaminated with an
        # empty by_requirement — async dominates :unhooked, because it
        # corrupts the hooked windows themselves. Unhooked-only degradation
        # stays on the :ok_per_test path so hooked-window MFA reach remains
        # visible.
        {:ok, %{mode: :per_test, degraded: true} = envelope} ->
          if windows_invalidated?(envelope) do
            Map.new(subjects, fn s ->
              {s.id, %{status: :async_contaminated, by_requirement: %{}}}
            end)
          else
            build_v2_ok(index, subjects, tracer_edges, envelope, tag_index, opts)
          end

        {:ok, envelope} ->
          build_v2_ok(index, subjects, tracer_edges, envelope, tag_index, opts)
      end
    end
  end

  defp build_v2_ok(index, subjects, tracer_edges, envelope, tag_index, opts) do
    world = %{subjects: subjects, tracer_edges: tracer_edges}
    status = if envelope.mode == :aggregate, do: :ok_aggregate, else: :ok_per_test
    attribution = per_test_attribution(envelope)
    unhooked = unhooked_modules(envelope)

    # Build requirement views once so the line index covers every closure
    # module in this review build (memoized for the build — not recomputed
    # per subject).
    subject_reqs =
      Map.new(subjects, fn subject ->
        closure = Closure.compute(subject, world)

        requirements =
          requirements_for(index, subject.id)
          |> Enum.map(fn req -> requirement_view(req, closure) end)

        {subject.id, {subject, requirements}}
      end)

    line_index =
      case Keyword.fetch(opts, :line_index) do
        {:ok, idx} when is_map(idx) ->
          idx

        :error ->
          if envelope.mode == :per_test do
            subject_reqs
            |> Enum.flat_map(fn {_id, {_subject, requirements}} ->
              Enum.flat_map(requirements, &closure_modules/1)
            end)
            |> Enum.uniq()
            |> MfaLines.index()
          else
            %{}
          end
      end

    closure_map = %{
      subjects:
        Map.new(subject_reqs, fn {subject_id, {subject, requirements}} ->
          {subject_id, %{owned_files: subject.surface, requirements: requirements}}
        end)
    }

    requirement_reach =
      case envelope.mode do
        :aggregate ->
          CoverageTriangulation.aggregate_requirement_reach(envelope, closure_map)

        :per_test ->
          per_test_reach_fn =
            Keyword.get(
              opts,
              :per_test_reach_fn,
              &CoverageTriangulation.per_test_requirement_reach/3
            )

          per_test_reach_fn.(
            envelope.payload,
            closure_map,
            line_index
          )
      end

    Map.new(subject_reqs, fn {subject_id, {_subject, requirements}} ->
      by_req =
        v2_by_requirement(
          envelope,
          requirement_reach,
          subject_id,
          requirements,
          tag_index
        )

      reach =
        %{status: status, by_requirement: by_req}
        |> maybe_put_attribution(status, attribution, unhooked)

      {subject_id, reach}
    end)
  end

  defp maybe_put_attribution(reach, :ok_per_test, attribution, unhooked) do
    reach
    |> Map.put(:attribution, attribution)
    |> Map.put(:unhooked_modules, unhooked)
  end

  defp maybe_put_attribution(reach, _status, _attribution, _unhooked), do: reach

  defp per_test_attribution(%{mode: :per_test, degraded: true} = envelope) do
    if :unhooked in degraded_reasons(envelope), do: :degraded_unhooked, else: :exact
  end

  defp per_test_attribution(%{mode: :per_test}), do: :exact
  defp per_test_attribution(_), do: :exact

  # `:async` and `:counters_harvested` corrupt the hooked windows themselves,
  # so no per-test claim survives them; `:unhooked` only omits coverage.
  defp windows_invalidated?(envelope) do
    reasons = degraded_reasons(envelope)
    :async in reasons or :counters_harvested in reasons
  end

  defp degraded_reasons(envelope), do: Store.degraded_reasons(envelope)

  defp unhooked_modules(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :unhooked_modules) || Map.get(meta, "unhooked_modules") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp unhooked_modules(_), do: []

  defp closure_modules(req) do
    req
    |> Map.get(:closure_mfas, [])
    |> Enum.flat_map(fn mfa_str ->
      case MfaKey.parse(mfa_str) do
        {:ok, {mod, _fun, _arity}} -> [mod]
        _ -> []
      end
    end)
  end

  defp resolve_envelope(opts, path) do
    case Keyword.fetch(opts, :envelope) do
      {:ok, atom} when atom in [:no_coverage_artifact, :legacy_artifact, :invalid_artifact] ->
        {:degraded, atom}

      {:ok, %{} = envelope} ->
        {:ok, envelope}

      :error ->
        Store.load(path)
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
         %{mode: :aggregate},
         requirement_reach,
         subject_id,
         requirements,
         tag_index
       ) do
    spec_tags = Map.get(tag_index, :spec, %{})

    Map.new(requirements, fn req ->
      r =
        Map.get(requirement_reach, {subject_id, req.id}, %{
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
         %{mode: :per_test},
         requirement_reach,
         subject_id,
         requirements,
         tag_index
       ) do
    spec_tags = Map.get(tag_index, :spec, %{})

    Map.new(requirements, fn req ->
      r =
        Map.get(requirement_reach, {subject_id, req.id}, %{
          closure_mfa_count: 0,
          executed_mfa_count: 0,
          covered_mfas: [],
          uncovered_mfas: [],
          no_debug_info_mfas: [],
          unresolvable_source_mfas: [],
          reaching_tests: []
        })

      reaching_tests = MapSet.new(r.reaching_tests)

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
      no_debug_info_mfas: Map.get(r, :no_debug_info_mfas, []),
      unresolvable_source_mfas: Map.get(r, :unresolvable_source_mfas, []),
      tagged_tests: tagged_tests,
      self_verified?: self_verified?
    }
  end
end
