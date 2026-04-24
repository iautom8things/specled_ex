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

  The default `enabled_tiers` list excludes `:implementation`. Dispatching it
  against the current repo surfaces a pre-existing AST shape mismatch between
  `SpecLedEx.Realization.Binding.resolve/2` (which returns
  `{fun, arity, clauses}` — an api_boundary-specific wrapper) and
  `SpecLedEx.Realization.Canonical.normalize/1` (which expects the standard
  Elixir `{name, meta, args}` AST that `Macro.prewalk/3` can walk). Fixing this
  requires reshaping either the resolver return or the impl tier's normalize
  call-site — both outside q59.9's Allowed touches. Opt in per-call via
  `enabled_tiers: [..., :implementation]` in controlled test contexts where the
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
    Drift,
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
    enabled = Keyword.get(opts, :enabled_tiers, @default_tiers)
    root = Keyword.get(opts, :root, File.cwd!())
    context = Keyword.get(opts, :context)
    umbrella? = Keyword.get(opts, :umbrella?, false)
    commit_hashes? = Keyword.get(opts, :commit_hashes?, true)

    tier_opts = [root: root, umbrella?: umbrella?]
    bindings_by_tier = collect_bindings(index, enabled)

    findings =
      Enum.flat_map(enabled, fn tier ->
        dispatch(tier, Map.get(bindings_by_tier, tier, []), context, tier_opts, umbrella?)
      end)

    findings = normalize_use_findings(findings)

    if commit_hashes? and not umbrella? and not has_drift?(findings) do
      refresh_and_commit_hashes(bindings_by_tier, context, root)
    end

    findings
  end

  # ---------------------------------------------------------------------------
  # Binding collection
  # ---------------------------------------------------------------------------

  defp collect_bindings(index, enabled) do
    subjects = index |> Map.get("subjects", []) |> List.wrap()
    init = Map.new(enabled, &{&1, []})

    Enum.reduce(subjects, init, fn subject, acc ->
      sid = subject_id(subject)
      surface = subject_surface(subject)
      subj_rb = extract_realized_by(subject_meta(subject))
      reqs = Map.get(subject, "requirements", []) |> List.wrap()

      req_bindings =
        Enum.map(reqs, fn r -> {requirement_id(r), extract_realized_by(r)} end)

      Enum.reduce(enabled, acc, fn tier, acc ->
        accumulate_tier(acc, tier, sid, surface, subj_rb, req_bindings)
      end)
    end)
  end

  defp accumulate_tier(acc, :implementation, sid, surface, subj_rb, req_bindings) do
    subj_mfas = Map.get(subj_rb, "implementation", [])

    req_mfas =
      Enum.flat_map(req_bindings, fn {_rid, rb} ->
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

  defp accumulate_tier(acc, tier, sid, _surface, subj_rb, req_bindings)
       when tier in @flat_tiers do
    tier_key = Atom.to_string(tier)

    subj_entries =
      Enum.map(Map.get(subj_rb, tier_key, []), fn mfa ->
        %{subject_id: sid, requirement_id: nil, mfa: mfa}
      end)

    req_entries =
      Enum.flat_map(req_bindings, fn {rid, rb} ->
        Enum.map(Map.get(rb, tier_key, []), fn mfa ->
          %{subject_id: sid, requirement_id: rid, mfa: mfa}
        end)
      end)

    entries = subj_entries ++ req_entries

    if entries == [] do
      acc
    else
      Map.update!(acc, tier, &(&1 ++ entries))
    end
  end

  defp accumulate_tier(acc, _other, _sid, _surface, _subj_rb, _reqs), do: acc

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
        is_map(f) and Map.get(f, :tier) == :use and Map.get(f, :code) == "branch_guard_realization_drift"
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
