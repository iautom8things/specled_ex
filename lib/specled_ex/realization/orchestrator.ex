defmodule SpecLedEx.Realization.Orchestrator do
  @moduledoc """
  Top-level dispatcher for realization tiers.

  Walks a spec index, collects the active `realized_by` bindings per tier, calls
  each enabled tier's `run/*` entrypoint, collapses macro-provider fan-out via
  `SpecLedEx.Realization.Drift.dedupe/2`, and (when the run produced no drift
  findings) commits current hashes to `SpecLedEx.Realization.HashStore`.

  `run/2` returns a flat list of string-keyed finding maps suitable for
  `SpecLedEx.BranchCheck` to merge into its report. Atom-keyed deltas from the
  `use` tier are normalized into the same string-keyed shape after deduping.

  ## Tier binding shapes

  Four tiers (`api_boundary`, `expanded_behavior`, `typespecs`, `use`) accept a
  flat list of `%{subject_id, requirement_id, mfa}` entries. The `implementation`
  tier is subject-scoped: it hashes the closure of each subject's declared
  `implementation` bindings, so the orchestrator aggregates subject-level and
  requirement-level `implementation` bindings into a single per-subject list
  before calling `Implementation.run/4`.

  ## Hash commit

  After a successful dispatch with no drift findings, the orchestrator refreshes
  current hashes for the four flat-binding tiers by calling each tier's public
  `hash/*` function and persists the result via `HashStore.write/2`. The
  `implementation` tier is excluded from hash commit in this iteration — its
  `hash_for_subject/3` requires a `world` map whose construction lives inside
  `Implementation`'s private API, and the Out of Scope clause on q59.9 forbids
  modifying tier internals. Follow-up work is expected to expose an implementation
  hash-refresh helper so the impl baseline can be seeded without re-running the
  tier.

  ## Implementation tier is opt-in

  The default `enabled_tiers` list excludes `:implementation`. In normal
  `mix spec.check` usage, opt in through `.spec/config.yml`:
  `realization.enabled_tiers: [api_boundary, implementation]`; `SpecLedEx.BranchCheck`
  threads that setting into this orchestrator. Dispatching the implementation tier
  against the current repo surfaces a pre-existing AST shape mismatch between
  `SpecLedEx.Realization.Binding.resolve/2` (which returns `{fun, arity, clauses}`
  — an api_boundary-specific wrapper) and `SpecLedEx.Realization.Canonical.normalize/1`
  (which expects the standard Elixir `{name, meta, args}` AST that `Macro.prewalk/3`
  can walk). Fixing this requires reshaping either the resolver return or the impl
  tier's normalize call-site — both outside q59.9's Allowed touches. Opt in per-call
  via `enabled_tiers: [..., :implementation]` in controlled test contexts where the
  bindings are known to be impl-friendly.

  ## Umbrella + debug_info_stripped

  Both degradations are delegated to the tiers. When `opts[:umbrella?]` is true,
  the orchestrator threads it through; each tier emits a single
  `detector_unavailable` with `reason: :umbrella_unsupported` and skips its
  binding walk. `:debug_info_stripped` is reported per module by the
  `expanded_behavior` and `typespecs` tiers.
  """

  alias SpecLedEx.Realization.{
    ApiBoundary,
    Binding,
    Canonical,
    Drift,
    EffectiveBinding,
    ExpandedBehavior,
    HashStore,
    Implementation,
    Typespecs,
    Use
  }

  @default_tiers [:api_boundary, :expanded_behavior, :typespecs, :use]
  @flat_tiers [:api_boundary, :expanded_behavior, :typespecs, :use]

  @type tier_key :: :api_boundary | :implementation | :expanded_behavior | :typespecs | :use
  @type binding_ref :: %{
          subject_id: String.t(),
          requirement_id: String.t() | nil,
          mfa: String.t()
        }
  @type impl_subject :: %{id: String.t(), surface: [String.t()], impl_bindings: [String.t()]}

  @spec default_tiers() :: [tier_key()]
  def default_tiers, do: @default_tiers

  @doc """
  Runs enabled realization tiers and returns string-keyed finding maps.

  Options:
    * `:enabled_tiers` — list of tier atoms; defaults to all five tiers.
    * `:context` — `%SpecLedEx.Compiler.Context{}`; passed through to tiers.
    * `:umbrella?` — when true, tiers emit a single `detector_unavailable` and
      skip binding work; the caller must set this at the task entry.
    * `:root` — project root for `HashStore` I/O; defaults to `File.cwd!/0`.
    * `:commit_hashes?` — when true and no drift findings are emitted, refresh
      current hashes for the flat-binding tiers and persist via
      `HashStore.write/2`. Defaults to true.
  """
  @spec run(map(), keyword()) :: [map()]
  def run(index, opts \\ []) when is_map(index) do
    {findings, _bindings_by_tier, _ctx} = do_run(index, opts)
    findings
  end

  @doc """
  Runs enabled realization tiers and returns `{findings, attestations}`.

  `findings` matches `run/2`'s return shape (a flat list of string-keyed maps).
  `attestations` is a per-`(subject_id, file)` map of shape
  `%{subject_id => %{normalized_path => {:attested_clean, [mfa]}}}`. It contains
  an entry for `(subject_id, path)` only when:

    * at least one of the subject's `realized_by` bindings resolves to `path`
      via `Binding.resolve_with_source/2`,
    * the resolved path is non-nil,
    * the binding's MFA does NOT appear in this run's
      `branch_guard_realization_drift` or `branch_guard_dangling_binding`
      findings, and
    * the path is normalized against `opts[:root]` via `Path.relative_to/2` so
      it matches the form used by `analysis.policy_files` keys.

  In addition, for each subject's `verification` blocks of `kind: tagged_tests`,
  every requirement listed under `covers:` whose `realized_by` bindings produced
  attestations on this run is expanded into the subject's attestation map: the
  requirement's test files (looked up via `index["test_tags"][requirement_id]`)
  receive an `{:attested_clean, [mfa]}` entry carrying the same MFA list as the
  production-code attestation produced by those bindings. Requirements whose
  bindings drifted or were dangling do not produce test-file attestations. See
  `specled.realized_by.attestation_tagged_tests_expansion`.

  Options match `run/2`.
  """
  @spec run_with_attestations(map(), keyword()) :: {[map()], %{String.t() => map()}}
  def run_with_attestations(index, opts \\ []) when is_map(index) do
    {findings, bindings_by_tier, ctx} = do_run(index, opts)
    attestations = build_attestations(findings, bindings_by_tier, ctx, index)
    {findings, attestations}
  end

  @doc """
  Returns the per-`(subject_id, file)` attestation map for this run.

  Equivalent to `elem(run_with_attestations(index, opts), 1)`. Use this when the
  caller only needs the attestation map and is not interested in the findings.
  """
  @spec attestations(map(), keyword()) :: %{String.t() => map()}
  def attestations(index, opts \\ []) when is_map(index) do
    {_findings, attestations} = run_with_attestations(index, opts)
    attestations
  end

  # ---------------------------------------------------------------------------
  # Shared run pipeline. Both `run/2` and `run_with_attestations/2` go through
  # here so bindings are collected, tiers dispatched, and hashes committed
  # exactly once per call regardless of which public entry-point was used.
  # The third element returned is a small "ctx" map carrying the root, context,
  # and umbrella flag so the attestation builder can re-resolve binding sources
  # without re-deriving option defaults.
  # ---------------------------------------------------------------------------
  defp do_run(index, opts) do
    enabled = Keyword.get(opts, :enabled_tiers, @default_tiers)
    root = Keyword.get(opts, :root, File.cwd!())
    context = Keyword.get(opts, :context)
    umbrella? = Keyword.get(opts, :umbrella?, false)
    commit_hashes? = Keyword.get(opts, :commit_hashes?, true)

    tier_opts = [root: root, umbrella?: umbrella?]
    bindings_by_tier = collect_bindings(index, enabled)

    if commit_hashes? and not umbrella? do
      seed_uncommitted_hashes(bindings_by_tier, context, root)
    end

    findings =
      Enum.flat_map(enabled, fn tier ->
        dispatch(tier, Map.get(bindings_by_tier, tier, []), context, tier_opts, umbrella?)
      end)

    findings = normalize_use_findings(findings)

    if commit_hashes? and not umbrella? and not has_drift?(findings) do
      refresh_and_commit_hashes(bindings_by_tier, context, root)
    end

    {findings, bindings_by_tier, %{root: root, context: context, umbrella?: umbrella?}}
  end

  # ---------------------------------------------------------------------------
  # Attestation map
  # ---------------------------------------------------------------------------

  # covers: specled.realized_by.orchestrator_publishes_attestations
  # covers: specled.realized_by.attestation_tagged_tests_expansion
  #
  # Build the per-(subject, file) attestation map for production-code bindings,
  # then expand `kind: tagged_tests` verification blocks into test-file
  # attestations.
  #
  # Phase 1 — production-code attestations.
  # For every binding the orchestrator collected across all flat tiers and the
  # implementation tier, we:
  #
  #   1. Check whether the `(subject_id, mfa)` pair appears in this run's
  #      drift/dangling finding set. If so, the binding is NOT clean — skip.
  #   2. Otherwise resolve the binding through `Binding.resolve_with_source/2`
  #      to get a source path. If the path is `nil` (e.g. hot-reloaded module
  #      without a recoverable `:source`), there's nothing to attest — skip.
  #   3. Normalize the path against the run's `root` opt via `Path.relative_to/2`
  #      so it matches the form `analysis.policy_files` uses.
  #   4. Accumulate `(subject_id, normalized_path) => {:attested_clean, [mfa]}`
  #      with MFAs collected in stable subject-then-requirement order, dedup'd.
  #
  # While walking the bindings, we also track, per `(subject_id, requirement_id)`,
  # which MFAs attested clean. That per-requirement bucket drives the tagged-
  # tests expansion below.
  #
  # Phase 2 — tagged-tests expansion.
  # For each subject's `verification` blocks of `kind: tagged_tests`, for each
  # requirement listed under `covers:` whose bucket from Phase 1 is non-empty,
  # we look up `index["test_tags"][requirement_id]` to get test files, then
  # add a `(subject_id, test_file_path) => {:attested_clean, [mfas...]}`
  # entry carrying the same MFAs the requirement contributed. Requirements
  # whose bindings drifted or were dangling have empty buckets and so don't
  # produce test-file attestations.
  defp build_attestations(findings, bindings_by_tier, ctx, index) do
    drift_set = drift_dangling_pairs(findings)

    {production_acc, req_clean_mfas} =
      bindings_by_tier
      |> all_subject_requirement_mfa_triples()
      |> Enum.reduce({%{}, %{}}, fn {subject_id, requirement_id, mfa}, {acc, req_acc} ->
        cond do
          MapSet.member?(drift_set, {subject_id, mfa}) ->
            {acc, req_acc}

          true ->
            case Binding.resolve_with_source(mfa, ctx.context) do
              {:ok, _ast, nil} ->
                {acc, req_acc}

              {:ok, _ast, path} when is_binary(path) ->
                normalized = normalize_attestation_path(path, ctx.root)
                acc2 = put_attestation(acc, subject_id, normalized, mfa)
                req_acc2 = track_clean_mfa(req_acc, subject_id, requirement_id, mfa)
                {acc2, req_acc2}

              _ ->
                {acc, req_acc}
            end
        end
      end)

    expand_tagged_tests(production_acc, req_clean_mfas, index, ctx.root)
  end

  # Track which MFAs attested clean for each (subject, requirement) pair. Only
  # requirement-level bindings (requirement_id != nil) participate — subject-
  # layer bindings don't tie to any specific requirement, so they can't drive
  # tagged_tests expansion on their own. (A subject-layer MFA does of course
  # still contribute to the subject's production attestation map above.)
  defp track_clean_mfa(req_acc, _subject_id, nil, _mfa), do: req_acc

  defp track_clean_mfa(req_acc, subject_id, requirement_id, mfa) do
    Map.update(
      req_acc,
      {subject_id, requirement_id},
      [mfa],
      fn existing -> if mfa in existing, do: existing, else: existing ++ [mfa] end
    )
  end

  # For each subject's tagged_tests verification blocks, expand each covered
  # requirement whose Phase-1 bucket has any clean MFAs into the test files
  # registered for that requirement under `index["test_tags"]`. The test-file
  # entry carries the same MFA list the requirement contributed.
  defp expand_tagged_tests(acc, req_clean_mfas, index, root) when is_map(index) do
    test_tags = Map.get(index, "test_tags") || %{}
    subjects = index |> Map.get("subjects", []) |> List.wrap()

    Enum.reduce(subjects, acc, fn subject, acc ->
      subject_id = subject_id(subject)

      subject
      |> tagged_tests_verifications()
      |> Enum.flat_map(&verification_covers/1)
      |> Enum.uniq()
      |> Enum.reduce(acc, fn requirement_id, acc ->
        case Map.get(req_clean_mfas, {subject_id, requirement_id}) do
          nil ->
            acc

          [] ->
            acc

          mfas ->
            test_tags
            |> Map.get(requirement_id, [])
            |> List.wrap()
            |> Enum.map(&tag_entry_file/1)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
            |> Enum.reduce(acc, fn test_file, acc ->
              normalized = normalize_attestation_path(test_file, root)

              Enum.reduce(mfas, acc, fn mfa, acc ->
                put_attestation(acc, subject_id, normalized, mfa)
              end)
            end)
        end
      end)
    end)
  end

  defp expand_tagged_tests(acc, _req_clean_mfas, _index, _root), do: acc

  # Filter a subject's verification list down to the `kind: tagged_tests`
  # blocks, tolerating both string- and atom-keyed shapes.
  defp tagged_tests_verifications(subject) do
    subject
    |> Map.get("verification", Map.get(subject, :verification, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn v ->
      kind = Map.get(v, "kind", Map.get(v, :kind))
      kind == "tagged_tests"
    end)
  end

  defp verification_covers(verification) do
    verification
    |> Map.get("covers", Map.get(verification, :covers, []))
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp tag_entry_file(entry) when is_map(entry),
    do: Map.get(entry, :file) || Map.get(entry, "file")

  defp tag_entry_file(entry) when is_binary(entry), do: entry
  defp tag_entry_file(_), do: nil

  # Flatten the bindings_by_tier map into a stream of
  # `{subject_id, requirement_id_or_nil, mfa}` triples. Subject-layer entries
  # precede requirement-layer entries (the same order accumulate_tier/7
  # produced) so the resulting MFA list per (subject, path) is deterministic.
  # Implementation-tier subjects carry an `impl_bindings` list of
  # MFAs/bare-modules — each contributes its own triple under that subject
  # with `requirement_id == nil` (the implementation tier aggregates subject-
  # and requirement-level impl bindings into a single per-subject list before
  # this point, so the requirement provenance is not preserved for impl).
  defp all_subject_requirement_mfa_triples(bindings_by_tier) do
    flat_triples =
      @flat_tiers
      |> Enum.flat_map(fn tier ->
        bindings_by_tier
        |> Map.get(tier, [])
        |> Enum.map(fn %{subject_id: sid, mfa: mfa} = entry ->
          {sid, Map.get(entry, :requirement_id), mfa}
        end)
      end)

    impl_triples =
      bindings_by_tier
      |> Map.get(:implementation, [])
      |> Enum.flat_map(fn %{id: sid, impl_bindings: mfas} ->
        Enum.map(mfas, fn mfa -> {sid, nil, mfa} end)
      end)

    Enum.uniq(flat_triples ++ impl_triples)
  end

  defp drift_dangling_pairs(findings) do
    Enum.reduce(findings, MapSet.new(), fn finding, acc ->
      code = Map.get(finding, "code") || Map.get(finding, :code)

      if code == "branch_guard_realization_drift" or code == "branch_guard_dangling_binding" do
        sid = Map.get(finding, "subject_id") || Map.get(finding, :subject_id)
        mfa = Map.get(finding, "mfa") || Map.get(finding, :mfa)

        if is_binary(sid) and is_binary(mfa) do
          MapSet.put(acc, {sid, mfa})
        else
          acc
        end
      else
        acc
      end
    end)
  end

  defp normalize_attestation_path(path, root) when is_binary(path) and is_binary(root) do
    # `resolve_with_source` already normalized against `File.cwd!/0`. When the
    # caller's root differs from cwd (test setups, umbrella sub-apps), we want
    # the attestation path to match the form `policy_files` keys use, which is
    # relative to the run's root. `Path.relative_to/2` on an already-relative
    # path is a no-op; on an absolute path it strips the root prefix when the
    # path lives under it and leaves the path unchanged otherwise.
    path
    |> Path.expand(root)
    |> Path.relative_to(root)
  end

  defp put_attestation(acc, subject_id, path, mfa) do
    inner = Map.get(acc, subject_id, %{})

    updated_inner =
      case Map.get(inner, path) do
        nil ->
          Map.put(inner, path, {:attested_clean, [mfa]})

        {:attested_clean, mfas} ->
          if mfa in mfas do
            inner
          else
            Map.put(inner, path, {:attested_clean, mfas ++ [mfa]})
          end
      end

    Map.put(acc, subject_id, updated_inner)
  end

  # ---------------------------------------------------------------------------
  # Binding collection
  # ---------------------------------------------------------------------------

  # covers: specled.realized_by.implication_invoked_per_layer
  # covers: specled.realized_by.implication_amplification_dedup
  defp collect_bindings(index, enabled) do
    subjects = index |> Map.get("subjects", []) |> List.wrap()
    init = Map.new(enabled, &{&1, []})

    bindings =
      Enum.reduce(subjects, init, fn subject, acc ->
        sid = subject_id(subject)
        surface = subject_surface(subject)

        {subj_rb, subj_inferred} =
          expand_with_inferred(extract_realized_by(subject_meta(subject)))

        reqs = Map.get(subject, "requirements", []) |> List.wrap()

        req_bindings =
          Enum.map(reqs, fn r ->
            {expanded, inferred} = expand_with_inferred(extract_realized_by(r))
            {requirement_id(r), expanded, inferred}
          end)

        Enum.reduce(enabled, acc, fn tier, acc ->
          accumulate_tier(acc, tier, sid, surface, subj_rb, subj_inferred, req_bindings)
        end)
      end)

    # Post-concat dedup: api_boundary tier only. The implication amplifies
    # bindings across layers (subject impl + requirement impl both inflate the
    # api_boundary list with the same MFA). Stable order means subject-layer
    # entries precede requirement-layer entries; uniq_by keeps the first-seen.
    # Other tiers are intentionally untouched — drift findings on the same
    # MFA from independent requirement_ids still convey distinct provenance.
    if Map.has_key?(bindings, :api_boundary) do
      Map.update!(bindings, :api_boundary, &Enum.uniq_by(&1, fn entry -> entry.mfa end))
    else
      bindings
    end
  end

  # Apply the one-way `implementation ⟹ api_boundary` implication to a
  # single binding map (per-layer) and return the expanded map plus the set
  # of api_boundary entries that were synthesized by the expansion (i.e.
  # were not already authored under api_boundary in the input). The inferred
  # set is consumed by accumulate_tier/7 to mark binding_refs with
  # `inferred?: true`, which the api_boundary detector uses to suppress
  # dangling findings (see `specled.realized_by.binding_ref_inferred_no_leak`).
  defp expand_with_inferred(rb) when is_map(rb) do
    original_api =
      rb
      |> Map.get("api_boundary", [])
      |> List.wrap()
      |> MapSet.new()

    expanded = EffectiveBinding.expand_implications(rb)

    inferred =
      expanded
      |> Map.get("api_boundary", [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.difference(original_api)

    {expanded, inferred}
  end

  defp expand_with_inferred(_), do: {%{}, MapSet.new()}

  defp accumulate_tier(acc, :implementation, sid, surface, subj_rb, _subj_inferred, req_bindings) do
    subj_mfas = Map.get(subj_rb, "implementation", [])

    req_mfas =
      Enum.flat_map(req_bindings, fn {_rid, rb, _inferred} ->
        Map.get(rb, "implementation", [])
      end)

    all_mfas = Enum.uniq(subj_mfas ++ req_mfas)

    if all_mfas == [] do
      acc
    else
      subject_map = %{id: sid, surface: surface, impl_bindings: all_mfas}
      Map.update!(acc, :implementation, &[subject_map | &1])
    end
  end

  defp accumulate_tier(acc, tier, sid, _surface, subj_rb, subj_inferred, req_bindings)
       when tier in @flat_tiers do
    tier_key = Atom.to_string(tier)
    inferred_supported? = tier == :api_boundary

    subj_entries =
      Enum.map(Map.get(subj_rb, tier_key, []), fn mfa ->
        entry = %{subject_id: sid, requirement_id: nil, mfa: mfa}

        if inferred_supported? and MapSet.member?(subj_inferred, mfa) do
          Map.put(entry, :inferred?, true)
        else
          entry
        end
      end)

    req_entries =
      Enum.flat_map(req_bindings, fn {rid, rb, inferred} ->
        Enum.map(Map.get(rb, tier_key, []), fn mfa ->
          entry = %{subject_id: sid, requirement_id: rid, mfa: mfa}

          if inferred_supported? and MapSet.member?(inferred, mfa) do
            Map.put(entry, :inferred?, true)
          else
            entry
          end
        end)
      end)

    entries = subj_entries ++ req_entries

    if entries == [] do
      acc
    else
      Map.update!(acc, tier, &(&1 ++ entries))
    end
  end

  defp accumulate_tier(acc, _other, _sid, _surface, _subj_rb, _subj_inferred, _reqs), do: acc

  # ---------------------------------------------------------------------------
  # Tier dispatch
  # ---------------------------------------------------------------------------

  # Under `umbrella?`, every enabled tier must emit its single
  # detector_unavailable finding regardless of whether any bindings are present.
  # When not under umbrella?, an empty binding list is a cheap skip — nothing to
  # check, no detector to report.
  defp dispatch(_tier, [], _context, _opts, false), do: []

  defp dispatch(tier, bindings, context, opts, _umbrella?) do
    run_tier(tier, bindings, context, opts)
  end

  defp run_tier(:api_boundary, bindings, context, opts) do
    ApiBoundary.run(bindings, context, opts)
  end

  defp run_tier(:implementation, subjects, context, opts) do
    Implementation.run(subjects, nil, context, opts)
  end

  defp run_tier(:expanded_behavior, bindings, context, opts) do
    ExpandedBehavior.run(bindings, context, opts)
  end

  defp run_tier(:typespecs, bindings, context, opts) do
    Typespecs.run(bindings, context, opts)
  end

  defp run_tier(:use, bindings, context, opts) do
    Use.run(bindings, context, opts)
  end

  # ---------------------------------------------------------------------------
  # Use-tier delta normalization (atom-keyed -> string-keyed + dedupe)
  # ---------------------------------------------------------------------------

  defp normalize_use_findings(findings) do
    {use_drifts, others} =
      Enum.split_with(findings, fn f ->
        is_map(f) and Map.get(f, :tier) == :use and
          Map.get(f, :code) == "branch_guard_realization_drift"
      end)

    if use_drifts == [] do
      others
    else
      # v1: no cross-subject dedupe for use-tier drifts (each subject's provider
      # is independent). The `false` predicate places each subject in its own
      # component, so dedupe only adds the root_cause annotation per-delta.
      deduped = Drift.dedupe(use_drifts, fn _a, _b -> false end)
      converted = Enum.map(deduped, &use_delta_to_finding/1)
      converted ++ others
    end
  end

  defp use_delta_to_finding(delta) do
    base =
      %{
        "code" => to_string(delta.code),
        "tier" => to_string(delta.tier),
        "subject_id" => delta.subject_id,
        "requirement_id" => Map.get(delta, :requirement_id),
        "mfa" => delta.mfa,
        "message" => delta.message
      }

    base
    |> maybe_put("root_cause", Map.get(delta, :root_cause))
    |> maybe_put("root_cause_of", Map.get(delta, :root_cause_of))
    |> maybe_put("provider", inspect_if(Map.get(delta, :provider)))
    |> maybe_put("hash_prefix_before", Map.get(delta, :hash_prefix_before))
    |> maybe_put("hash_prefix_after", Map.get(delta, :hash_prefix_after))
    |> maybe_put("consumers", map_inspect(Map.get(delta, :consumers)))
  end

  defp inspect_if(nil), do: nil
  defp inspect_if(mod) when is_atom(mod), do: inspect(mod)
  defp inspect_if(other), do: other

  defp map_inspect(nil), do: nil
  defp map_inspect(list) when is_list(list), do: Enum.map(list, &inspect/1)

  # ---------------------------------------------------------------------------
  # Hash commit (4 of 5 tiers — see moduledoc for impl-tier exclusion rationale)
  # ---------------------------------------------------------------------------

  defp has_drift?(findings) do
    Enum.any?(findings, fn f ->
      code =
        Map.get(f, "code") || Map.get(f, :code)

      code == "branch_guard_realization_drift" or
        code == "branch_guard_dangling_binding"
    end)
  end

  # covers: specled.realized_by.silent_seed
  # covers: specled.realized_by.silent_seed_uses_merge
  #
  # Pre-dispatch silent-seed pass. For each tracked entry that lacks a
  # committed hash in `<root>/.spec/realization_hashes.json`, compute the
  # current hash and persist it via `HashStore.merge/2`. The detectors then read the
  # committed-by-this-pass hash on entry, see `committed == current`, and
  # emit no drift finding for that entry on the seeding run.
  #
  # Gated by the same `commit_hashes? != false` and `umbrella? == false`
  # conditions that gate `refresh_and_commit_hashes/3`. Dangling entries
  # (MFAs that don't resolve, bare modules that aren't loadable, impl
  # subjects with dangling closure bindings) are NOT seeded — they continue
  # to surface as dangling findings on this run.
  #
  # The seed pass is silent: no findings are emitted from this code path.
  # The post-run `refresh_and_commit_hashes/3` is unaffected; it still runs
  # under the same gate when no drift is detected and uses `write/2`'s
  # replacement semantics for the full realization map.
  defp seed_uncommitted_hashes(bindings_by_tier, context, root) do
    store = HashStore.read(root)

    flat_seeds =
      Enum.reduce(@flat_tiers, %{}, fn tier, acc ->
        tier_key = Atom.to_string(tier)
        committed = Map.get(store, tier_key, %{})
        bindings = Map.get(bindings_by_tier, tier, [])

        uncommitted =
          Enum.reject(bindings, fn %{mfa: mfa} -> Map.has_key?(committed, mfa) end)

        case compute_seed_hashes(tier, uncommitted, context) do
          empty when empty == %{} -> acc
          tier_seeds -> Map.put(acc, tier_key, tier_seeds)
        end
      end)

    impl_seeds =
      seed_implementation_subjects(
        Map.get(bindings_by_tier, :implementation, []),
        Map.get(store, "implementation", %{}),
        context,
        root
      )

    seeds =
      if impl_seeds == %{} do
        flat_seeds
      else
        Map.put(flat_seeds, "implementation", impl_seeds)
      end

    if seeds != %{} do
      HashStore.merge(root, seeds)
    end

    :ok
  end

  defp compute_seed_hashes(:api_boundary, bindings, context) do
    Enum.reduce(bindings, %{}, fn %{mfa: mfa}, acc ->
      case Binding.resolve(mfa, context) do
        {:ok, {:module, mod}} ->
          # Bare module under api_boundary — head-union envelope.
          case Canonical.hash_module_head_union(mod) do
            {:ok, hash_bin} -> Map.put(acc, mfa, hash_entry(hash_bin))
            _ -> acc
          end

        {:ok, ast} ->
          hash_bin = ApiBoundary.hash(ast)
          Map.put(acc, mfa, hash_entry(hash_bin))

        _ ->
          # Dangling: do not seed. Detector will emit dangling on the run.
          acc
      end
    end)
  end

  defp compute_seed_hashes(:expanded_behavior, bindings, _context) do
    dedupe_by_mfa(bindings, fn mfa ->
      case ExpandedBehavior.hash(mfa) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_seed_hashes(:typespecs, bindings, _context) do
    dedupe_by_mfa(bindings, fn mfa ->
      case Typespecs.hash(mfa) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_seed_hashes(:use, bindings, _context) do
    dedupe_by_mfa(bindings, fn provider ->
      case Use.hash(provider) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_seed_hashes(_tier, _bindings, _context), do: %{}

  # Implementation tier seeding: subjects carry a mixed `impl_bindings` list
  # (MFA-form for closure walk, bare-module-form for per-module hashing).
  # Each closure subject is keyed by `subject.id`; each bare module is keyed
  # by the module string. Both go under `realization.implementation`. Subjects
  # whose MFAs all dangle drop out of the closure-hash result; bare modules
  # that fail to load are skipped (the detector emits dangling separately).
  #
  # Closure hashes MUST be computed across the FULL subject graph in a single
  # `hashes_for_seeding/3` call, then filtered to uncommitted ids for write.
  # Hash-ref composition embeds peer subject hashes (`subject:B:hash:…`);
  # seeding one subject (or only the uncommitted subset) builds a world that
  # cannot resolve peers, so the seed writes `…:hash:unknown` markers and the
  # detector (which walks the full subject graph) permanently reports
  # wholesale `branch_guard_realization_drift`. See atlas-vmi.
  defp seed_implementation_subjects(subjects, committed, context, root) do
    bare_seeds =
      Enum.reduce(subjects, %{}, fn subject, acc ->
        seed_impl_bare_modules(acc, subject, committed)
      end)

    # Pass the FULL subject list (MFA + bare-module bindings) into
    # hashes_for_seeding so world building sees the same in_project set and
    # peer graph as Implementation.run/4. hashes_for_seeding partitions bare
    # modules out of each subject's declared bindings before hashing.
    needs_seed? =
      Enum.any?(subjects, fn subject ->
        has_mfa_binding?(subject) and not Map.has_key?(committed, subject.id)
      end)

    closure_seeds =
      cond do
        subjects == [] or not needs_seed? ->
          %{}

        true ->
          subjects
          |> Implementation.hashes_for_seeding(context, root: root)
          |> Enum.reduce(%{}, fn {id, hash_bin}, acc ->
            if Map.has_key?(committed, id) do
              acc
            else
              Map.put(acc, id, hash_entry(hash_bin))
            end
          end)
      end

    Map.merge(bare_seeds, closure_seeds)
  end

  defp has_mfa_binding?(subject) do
    subject
    |> Map.get(:impl_bindings, [])
    |> Enum.any?(fn binding -> not bare_module_binding?(binding) end)
  end

  defp seed_impl_bare_modules(acc, subject, committed) do
    subject
    |> Map.get(:impl_bindings, [])
    |> Enum.filter(&bare_module_binding?/1)
    |> Enum.reduce(acc, fn module_string, inner_acc ->
      cond do
        Map.has_key?(committed, module_string) ->
          inner_acc

        true ->
          case Binding.parse(module_string) do
            {:ok, {:module, mod}} ->
              case Canonical.hash_module_full_union(mod) do
                {:ok, hash_bin} -> Map.put(inner_acc, module_string, hash_entry(hash_bin))
                _ -> inner_acc
              end

            _ ->
              inner_acc
          end
      end
    end)
  end

  defp bare_module_binding?(binding) when is_binary(binding) do
    case Binding.parse(binding) do
      {:ok, {:module, _}} -> true
      _ -> false
    end
  end

  defp bare_module_binding?(_), do: false

  defp refresh_and_commit_hashes(bindings_by_tier, context, root) do
    realization =
      @flat_tiers
      |> Enum.reduce(%{}, fn tier, acc ->
        bindings = Map.get(bindings_by_tier, tier, [])
        tier_hashes = compute_tier_hashes(tier, bindings, context)

        if tier_hashes == %{} do
          acc
        else
          Map.put(acc, Atom.to_string(tier), tier_hashes)
        end
      end)

    if realization != %{} do
      HashStore.write(root, realization)
    end

    :ok
  end

  defp compute_tier_hashes(:api_boundary, bindings, context) do
    Enum.reduce(bindings, %{}, fn %{mfa: mfa}, acc ->
      case Binding.resolve(mfa, context) do
        {:ok, {:module, _}} ->
          acc

        {:ok, ast} ->
          hash_bin = ApiBoundary.hash(ast)
          Map.put(acc, mfa, hash_entry(hash_bin))

        _ ->
          acc
      end
    end)
  end

  defp compute_tier_hashes(:expanded_behavior, bindings, _context) do
    dedupe_by_mfa(bindings, fn mfa ->
      case ExpandedBehavior.hash(mfa) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_tier_hashes(:typespecs, bindings, _context) do
    dedupe_by_mfa(bindings, fn mfa ->
      case Typespecs.hash(mfa) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_tier_hashes(:use, bindings, _context) do
    dedupe_by_mfa(bindings, fn provider ->
      case Use.hash(provider) do
        {:ok, hash_bin} -> {:ok, hash_bin}
        _ -> :skip
      end
    end)
  end

  defp compute_tier_hashes(_tier, _bindings, _context), do: %{}

  defp dedupe_by_mfa(bindings, hash_fun) do
    bindings
    |> Enum.uniq_by(& &1.mfa)
    |> Enum.reduce(%{}, fn %{mfa: mfa}, acc ->
      case hash_fun.(mfa) do
        {:ok, hash_bin} -> Map.put(acc, mfa, hash_entry(hash_bin))
        :skip -> acc
      end
    end)
  end

  defp hash_entry(hash_bin) do
    %{
      "hash" => Base.encode16(hash_bin, case: :lower),
      "hasher_version" => HashStore.hasher_version()
    }
  end

  # ---------------------------------------------------------------------------
  # Index shape helpers (tolerate struct/map + atom/string keys)
  # ---------------------------------------------------------------------------

  defp subject_meta(subject), do: subject["meta"] || Map.get(subject, :meta) || %{}

  defp subject_id(subject) do
    meta = subject_meta(subject)
    get_field(meta, :id, "id") || get_field(subject, :id, "id")
  end

  defp subject_surface(subject) do
    meta = subject_meta(subject)
    get_field(meta, :surface, "surface") || []
  end

  defp requirement_id(req), do: get_field(req, :id, "id")

  defp extract_realized_by(nil), do: %{}

  defp extract_realized_by(container) do
    case get_field(container, :realized_by, "realized_by") do
      nil -> %{}
      %{} = rb -> normalize_tier_keys(rb)
      _ -> %{}
    end
  end

  defp normalize_tier_keys(rb) do
    Map.new(rb, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end

  defp get_field(%{} = map, atom_key, string_key) do
    case Map.fetch(map, atom_key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, string_key)
    end
  end

  defp get_field(_, _, _), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
