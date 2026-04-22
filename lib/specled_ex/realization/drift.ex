defmodule SpecLedEx.Realization.Drift do
  # covers: specled.use_tier.root_cause_dedupe
  # covers: specled.use_tier.hash_prefix_length
  # covers: specled.use_tier.scenario_macro_provider_drift
  @moduledoc """
  Deduplicates realization deltas across a dependency graph.

  Exactly one exported function: `dedupe/2`. Hard-capped at 150 LOC including
  this moduledoc — later tiers compose this; they do not extend it.

  Input: a list of delta maps (each with `:subject_id`) and a dependency
  predicate `pred.(a, b) :: boolean()` returning true if subject `a` depends on
  subject `b`. Output: deltas with `:root_cause_of` annotations for providers
  and dropped entries for consumers whose provider is in the same batch.

  Cyclic connected components are detected: when subjects form a cycle without
  a clear root, the lexicographically smallest id wins deterministically
  (see `specled.api_boundary.dedupe_cyclic_tiebreak`).

  Macro-provider root cause: a delta carrying `tier: :use` is always picked as
  the root for its component, and is reshaped with a `:root_cause` map naming
  the provider, hash prefixes, and consumer modules — collapsing the per-
  consumer expanded_behavior drifts into one finding per provider.
  """

  @doc """
  Deduplicates deltas.

  Per connected component (by dependency), picks one subject as the root cause
  and drops the rest. The root-cause delta carries `:root_cause_of` with the
  dropped subject ids. When the root delta carries `tier: :use`, the result
  also carries a `:root_cause` map with the macro-provider shape.
  """
  @spec dedupe([map()], (String.t(), String.t() -> boolean())) :: [map()]
  def dedupe(deltas, pred) when is_list(deltas) and is_function(pred, 2) do
    ids = Enum.map(deltas, & &1.subject_id) |> Enum.uniq() |> Enum.sort()
    adj = build_adjacency(ids, pred)
    components = connected_components(ids, adj)

    components
    |> Enum.flat_map(fn comp ->
      root = pick_root(comp, adj, deltas)
      dropped = comp -- [root]

      root_delta =
        deltas
        |> Enum.find(&(&1.subject_id == root))
        |> Map.put(:root_cause_of, dropped)
        |> maybe_add_root_cause()

      [root_delta]
    end)
    |> Enum.sort_by(& &1.subject_id)
  end

  defp build_adjacency(ids, pred) do
    Enum.into(ids, %{}, fn id ->
      deps = Enum.filter(ids, fn other -> other != id and pred.(id, other) end)
      {id, deps}
    end)
  end

  defp connected_components(ids, adj) do
    undirected = Enum.into(adj, %{}, fn {id, deps} -> {id, MapSet.new(deps)} end)

    undirected =
      Enum.reduce(adj, undirected, fn {id, deps}, acc ->
        Enum.reduce(deps, acc, fn dep, acc2 ->
          Map.update(acc2, dep, MapSet.new([id]), &MapSet.put(&1, id))
        end)
      end)

    {components, _} =
      Enum.reduce(ids, {[], MapSet.new()}, fn id, {comps, visited} ->
        if MapSet.member?(visited, id) do
          {comps, visited}
        else
          {comp, visited} = bfs(id, undirected, visited)
          {[Enum.sort(comp) | comps], visited}
        end
      end)

    Enum.reverse(components)
  end

  defp bfs(start, undirected, visited) do
    do_bfs([start], undirected, MapSet.put(visited, start), [start])
  end

  defp do_bfs([], _undirected, visited, acc), do: {acc, visited}

  defp do_bfs([node | rest], undirected, visited, acc) do
    neighbors = Map.get(undirected, node, MapSet.new())

    {visited, acc, queue} =
      Enum.reduce(neighbors, {visited, acc, rest}, fn n, {v, a, q} ->
        if MapSet.member?(v, n), do: {v, a, q}, else: {MapSet.put(v, n), [n | a], q ++ [n]}
      end)

    do_bfs(queue, undirected, visited, acc)
  end

  defp pick_root(comp, adj, deltas) do
    case Enum.find(deltas, fn d -> d.subject_id in comp and Map.get(d, :tier) == :use end) do
      %{subject_id: id} ->
        id

      nil ->
        providers =
          Enum.filter(comp, fn id ->
            Enum.all?(comp, fn other ->
              other == id or not Enum.member?(Map.get(adj, id, []), other)
            end)
          end)

        candidates = if providers == [], do: comp, else: providers
        Enum.min(candidates)
    end
  end

  defp maybe_add_root_cause(%{tier: :use} = delta) do
    consumers = Map.get(delta, :consumers, [])

    Map.put(delta, :root_cause, %{
      provider: Map.get(delta, :provider_mfa) || Map.get(delta, :provider),
      tier: :use,
      hash_prefix_before: Map.get(delta, :hash_prefix_before),
      hash_prefix_after: Map.get(delta, :hash_prefix_after),
      consumers_affected: length(consumers),
      consumers: consumers
    })
  end

  defp maybe_add_root_cause(delta), do: delta
end
