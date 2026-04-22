defmodule SpecLedEx.Realization.Implementation do
  # covers: specled.implementation_tier.hash_ref_composition
  # covers: specled.implementation_tier.scenario_refactor_stable
  @moduledoc """
  Second realization tier. Follows the tracer-emitted MFA callee graph out from
  each subject's declared `implementation` bindings, hashes the closure bounded
  by subject ownership, and emits `branch_guard_realization_drift` (and
  `branch_guard_dangling_binding`) findings.

  Closure membership is decided by `SpecLedEx.Realization.Closure`. The hash
  input for subject `A` is a deterministic term containing

    1. the canonical AST of every `A`-owned MFA in the closure,
    2. the canonical AST of every shared-helper MFA inlined into the closure, and
    3. for each other subject `B` reached by the walk, the string
       `"subject:\#{B.id}:hash:\#{B.impl_hash}"` — **not** `B`'s canonical AST.

  The third point is the Cargo hash-ref composition rule
  (`specled.implementation_tier.hash_ref_composition`): when `B`'s impl hash
  changes, `A`'s hash flips via the reference, keeping drift findings
  composable without inlining upstream ASTs.

  ## Umbrella graceful degrade

  When `opts[:umbrella?]` is true a single `detector_unavailable` finding with
  reason `umbrella_unsupported` is emitted and no binding walk is attempted.
  Mirrors `SpecLedEx.Realization.ApiBoundary` behavior for symmetry.
  """

  alias SpecLedEx.Compiler.Context
  alias SpecLedEx.Compiler.Tracer
  alias SpecLedEx.Realization.{Binding, Canonical, Closure, HashStore}

  @tier "implementation"
  @drift_code "branch_guard_realization_drift"
  @dangling_code "branch_guard_dangling_binding"
  @detector_unavailable_code "detector_unavailable"

  @type subject :: Closure.subject()
  @type world :: Closure.world()

  @doc """
  Runs the implementation tier for a list of subjects.

  `world` carries the call graph and ownership information. When `world` is
  `nil`, the orchestrator builds it from the supplied `context` (reading the
  tracer ETF side-manifest and using each subject's `surface`/`impl_bindings`).
  """
  @spec run([subject()], world() | nil, Context.t() | nil, keyword()) :: [map()]
  def run(subjects, world \\ nil, context \\ nil, opts \\ []) do
    cond do
      Keyword.get(opts, :umbrella?, false) ->
        [
          %{
            "code" => @detector_unavailable_code,
            "reason" => "umbrella_unsupported",
            "message" =>
              "implementation tier does not support umbrella apps in v1. " <>
                "Re-run per umbrella child app or wait for v1.1."
          }
        ]

      true ->
        root = Keyword.get(opts, :root, File.cwd!())
        store = HashStore.read(root)
        world = world || build_world(subjects, context, opts)

        sorted_subjects = Enum.sort_by(subjects, & &1.id)

        {findings, _cache} =
          Enum.reduce(sorted_subjects, {[], %{}}, fn subject, {acc, cache} ->
            {subject_findings, cache} = check_subject(subject, world, context, store, cache)
            {acc ++ subject_findings, cache}
          end)

        findings
    end
  end

  @doc """
  Computes the implementation hash for a single subject. Exposed for testing
  and for callers that want to commit the current hash to `HashStore`.

  Returns `{:ok, <sha256 binary>}` or `{:error, {:dangling_bindings, [mfa_strings]}}`
  when one or more declared `implementation` bindings do not resolve.
  """
  @spec hash_for_subject(subject(), world(), Context.t() | nil) ::
          {:ok, binary()} | {:error, {:dangling_bindings, [String.t()]}}
  def hash_for_subject(subject, world, context \\ nil) do
    case compute_hash(subject, world, context, %{}) do
      {:ok, hash, _cache} -> {:ok, hash}
      {:error, reason, _cache} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Per-subject check
  # ---------------------------------------------------------------------------

  defp check_subject(subject, world, context, store, cache) do
    case compute_hash(subject, world, context, cache) do
      {:ok, hash, cache} ->
        committed = HashStore.fetch(store, @tier, subject.id)

        findings =
          cond do
            committed == nil -> []
            committed == hash -> []
            true -> [drift_finding(subject, hash, committed)]
          end

        {findings, cache}

      {:error, {:dangling_bindings, bindings}, cache} ->
        {Enum.map(bindings, &dangling_finding(subject, &1)), cache}
    end
  end

  defp drift_finding(subject, current, _committed) do
    %{
      "code" => @drift_code,
      "tier" => @tier,
      "subject_id" => subject.id,
      "requirement_id" => nil,
      "mfa" => subject.id,
      "current_hash" => Base.encode16(current, case: :lower),
      "message" =>
        "implementation hash for subject #{subject.id} differs from committed value"
    }
  end

  defp dangling_finding(subject, binding) do
    %{
      "code" => @dangling_code,
      "tier" => @tier,
      "subject_id" => subject.id,
      "requirement_id" => nil,
      "mfa" => binding,
      "message" =>
        "Declared implementation binding #{binding} is not defined " <>
          "(subject=#{subject.id}, tier=#{@tier}). " <>
          "Update realized_by or restore the function."
    }
  end

  # ---------------------------------------------------------------------------
  # Hash composition
  # ---------------------------------------------------------------------------

  defp compute_hash(subject, world, context, cache) do
    cond do
      Map.has_key?(cache, {:hash, subject.id}) ->
        {:ok, Map.fetch!(cache, {:hash, subject.id}), cache}

      MapSet.member?(Map.get(cache, :in_progress, MapSet.new()), subject.id) ->
        # Cycle guard — return a stable sentinel hash so the caller can still
        # compose its own hash without looping. The per-run memo is warm; the
        # cycle marker is deterministic across runs.
        sentinel = :crypto.hash(:sha256, "subject:#{subject.id}:cycle")
        {:ok, sentinel, cache}

      true ->
        in_progress =
          cache
          |> Map.get(:in_progress, MapSet.new())
          |> MapSet.put(subject.id)

        cache = Map.put(cache, :in_progress, in_progress)

        closure = Closure.compute(subject, world)

        case resolve_mfa_asts(closure.owned_mfas, subject, world, context) do
          {:ok, owned_asts} ->
            shared_asts = resolve_shared_mfas(closure.shared_mfas, subject, world, context)

            {ref_tuples, cache} =
              compute_referenced_hashes(closure.referenced_subjects, world, context, cache)

            hash_input = {
              :__spec_impl_hash__,
              subject.id,
              Enum.map(owned_asts, fn {mfa, ast} -> {mfa, deep_strip_meta(ast)} end),
              Enum.map(shared_asts, fn {mfa, ast} -> {mfa, deep_strip_meta(ast)} end),
              ref_tuples
            }

            hash = Canonical.hash(hash_input)

            cache =
              cache
              |> Map.put({:hash, subject.id}, hash)
              |> Map.update(:in_progress, MapSet.new(), &MapSet.delete(&1, subject.id))

            {:ok, hash, cache}

          {:error, missing} ->
            cache = Map.update(cache, :in_progress, MapSet.new(), &MapSet.delete(&1, subject.id))
            {:error, {:dangling_bindings, missing}, cache}
        end
    end
  end

  defp resolve_mfa_asts(owned_mfas, subject, world, context) do
    declared_strings = MapSet.new(Map.get(subject, :impl_bindings, []))

    {entries, missing} =
      Enum.reduce(owned_mfas, {[], []}, fn mfa, {entries, missing} ->
        mfa_string = mfa_to_string(mfa)

        case Binding.resolve(mfa_string, context) do
          {:ok, {:module, _}} ->
            {entries, missing}

          {:ok, ast} ->
            normalized = Canonical.normalize(ast)
            {[{mfa_string, normalized} | entries], missing}

          {:error, :not_found, _details} ->
            cond do
              MapSet.member?(declared_strings, mfa_string) ->
                {entries, [mfa_string | missing]}

              # MFA reached via walk but source unavailable — drop rather than
              # fail the whole subject. The walk itself does not author the
              # binding; only declared bindings are user-owned contracts.
              true ->
                _ = world
                {entries, missing}
            end
        end
      end)

    if missing == [] do
      {:ok, Enum.sort_by(entries, &elem(&1, 0))}
    else
      {:error, Enum.sort(missing)}
    end
  end

  defp resolve_shared_mfas(shared_mfas, _subject, _world, context) do
    shared_mfas
    |> Enum.flat_map(fn mfa ->
      mfa_string = mfa_to_string(mfa)

      case Binding.resolve(mfa_string, context) do
        {:ok, {:module, _}} -> []
        {:ok, ast} -> [{mfa_string, Canonical.normalize(ast)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp compute_referenced_hashes(referenced_ids, world, context, cache) do
    subjects_by_id = Map.new(Map.get(world, :subjects, []), fn s -> {s.id, s} end)

    Enum.reduce(Enum.sort(referenced_ids), {[], cache}, fn id, {acc, cache} ->
      case Map.fetch(subjects_by_id, id) do
        {:ok, ref_subject} ->
          case compute_hash(ref_subject, world, context, cache) do
            {:ok, ref_hash, cache} ->
              hex = Base.encode16(ref_hash, case: :lower)
              {[{:subject_ref, "subject:#{id}:hash:#{hex}"} | acc], cache}

            {:error, _, cache} ->
              {[{:subject_ref, "subject:#{id}:hash:unresolved"} | acc], cache}
          end

        :error ->
          {[{:subject_ref, "subject:#{id}:hash:unknown"} | acc], cache}
      end
    end)
    |> then(fn {acc, cache} -> {Enum.sort(acc), cache} end)
  end

  # ---------------------------------------------------------------------------
  # World building (when the caller passes a Context rather than a world map)
  # ---------------------------------------------------------------------------

  defp build_world(subjects, context, opts) do
    edges = load_tracer_edges(context, opts)
    manifest = if context, do: context.manifest, else: nil

    %{
      subjects: subjects,
      tracer_edges: edges,
      manifest: manifest,
      in_project?: in_project_set(subjects, manifest)
    }
  end

  defp load_tracer_edges(nil, opts) do
    path = Keyword.get(opts, :tracer_manifest, Tracer.manifest_path())
    read_tracer_etf(path)
  end

  defp load_tracer_edges(%Context{tracer_table: table}, _opts) when not is_nil(table) do
    try do
      :ets.tab2list(table)
      |> Enum.reduce(%{}, fn {caller, callee}, acc ->
        Map.update(acc, caller, [callee], fn list ->
          if callee in list, do: list, else: [callee | list]
        end)
      end)
    rescue
      ArgumentError -> %{}
    end
  end

  defp load_tracer_edges(_context, opts) do
    path = Keyword.get(opts, :tracer_manifest, Tracer.manifest_path())
    read_tracer_etf(path)
  end

  defp read_tracer_etf(path) do
    case File.read(path) do
      {:ok, binary} ->
        try do
          case :erlang.binary_to_term(binary) do
            map when is_map(map) -> map
            _ -> %{}
          end
        rescue
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp in_project_set(subjects, manifest) do
    from_manifest =
      if is_map(manifest), do: manifest |> Map.keys() |> MapSet.new(), else: MapSet.new()

    # Anchor: modules that match subjects' surface files via `Code.get_module`
    # would require load, so we fall back to the manifest-provided keys plus any
    # module declared in an `impl_bindings` MFA.
    from_bindings =
      subjects
      |> Enum.flat_map(fn s -> Map.get(s, :impl_bindings, []) end)
      |> Enum.flat_map(&binding_module/1)
      |> MapSet.new()

    MapSet.union(from_manifest, from_bindings)
  end

  defp binding_module(binding) when is_binary(binding) do
    case String.split(binding, "/") do
      [prefix, _arity] ->
        case String.split(prefix, ".") do
          parts when length(parts) >= 2 ->
            {mod_parts, [_fun]} = Enum.split(parts, -1)
            [Module.concat(mod_parts)]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp binding_module(_), do: []

  defp mfa_to_string({mod, fun, arity}) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  # `Canonical.strip_meta/1` only recurses into an AST node's `args` position,
  # not into the `form` position. Line metadata on remote-call dot expressions
  # (`{:., [line: N], [...]}`) survives normalization and makes the hash flip
  # when only the line number shifted. This deep pass strips meta from form
  # tuples too, which is necessary for scenario.refactor_does_not_drift.
  defp deep_strip_meta({form, _meta, args}) when is_list(args) do
    {deep_strip_meta(form), [], Enum.map(args, &deep_strip_meta/1)}
  end

  defp deep_strip_meta({form, _meta, ctx}) when is_atom(ctx) do
    {deep_strip_meta(form), [], ctx}
  end

  defp deep_strip_meta({left, right}) do
    {deep_strip_meta(left), deep_strip_meta(right)}
  end

  defp deep_strip_meta(list) when is_list(list) do
    Enum.map(list, &deep_strip_meta/1)
  end

  defp deep_strip_meta(other), do: other
end
