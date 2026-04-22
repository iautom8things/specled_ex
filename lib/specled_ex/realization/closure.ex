defmodule SpecLedEx.Realization.Closure do
  # covers: specled.implementation_tier.closure_walks_tracer_edges
  # covers: specled.implementation_tier.ownership_rule
  # covers: specled.implementation_tier.shared_helper_accounting
  @moduledoc """
  Computes the implementation-tier closure for a subject.

  `compute/2` walks MFA callee edges from the tracer side-manifest starting at
  the subject's declared `implementation` bindings, stopping at

    * subject boundaries (an MFA owned by another subject),
    * MFAs outside the project's in-tree modules, and
    * already-visited MFAs (cycle guard).

  `subject_for_mfa/2` applies the MFA ownership rule:

    1. If the MFA appears in some subject's `realized_by.implementation`
       binding, that subject owns it.
    2. Otherwise the file-level mapping from `spec-meta.surface` is used; the
       file that contains the MFA's defining source is matched against each
       subject's surface entries. Ties are broken by choosing the subject whose
       id sorts lexicographically smallest.
    3. If no subject owns the MFA, it is a shared helper — it is inlined into
       every caller's closure rather than referenced by id.

  The `world` argument carries everything a pure walk needs: the list of
  subjects, the callee edge map, an in-project membership check, and an
  optional `Manifest`-shaped map from module → source paths.
  """

  alias SpecLedEx.Compiler.Manifest

  @type mfa_tuple :: {module(), atom(), non_neg_integer()}

  @type subject :: %{
          required(:id) => String.t(),
          required(:surface) => [Path.t()],
          required(:impl_bindings) => [String.t()]
        }

  @type world :: %{
          required(:subjects) => [subject()],
          required(:tracer_edges) => %{optional(mfa_tuple()) => [mfa_tuple()]},
          optional(:in_project?) => (module() -> boolean()) | MapSet.t(),
          optional(:manifest) => map()
        }

  @type set_t :: %{
          subject_id: String.t(),
          owned_mfas: [mfa_tuple()],
          shared_mfas: [mfa_tuple()],
          referenced_subjects: [String.t()]
        }

  @doc """
  Walks the tracer-edge graph for `subject`, returning the closure set.

  The return value is a map with deterministically sorted lists:

    * `:owned_mfas` — MFAs owned by this subject that contribute their
      canonical AST to the subject's impl hash.
    * `:shared_mfas` — shared-helper MFAs (orphans) inlined into this subject's
      closure.
    * `:referenced_subjects` — other subject ids whose current impl hash should
      be included by reference (Cargo hash-ref composition).
  """
  @spec compute(subject(), world()) :: set_t()
  def compute(subject, world) when is_map(subject) and is_map(world) do
    starting_mfas = starting_mfas(subject)

    acc = %{
      subject_id: subject.id,
      visited: MapSet.new(),
      owned: [],
      shared: [],
      referenced: MapSet.new()
    }

    acc = Enum.reduce(starting_mfas, acc, fn mfa, acc -> walk(mfa, subject, world, acc) end)

    %{
      subject_id: subject.id,
      owned_mfas: Enum.sort(acc.owned),
      shared_mfas: Enum.sort(acc.shared),
      referenced_subjects: acc.referenced |> MapSet.to_list() |> Enum.sort()
    }
  end

  @doc """
  Returns the owner of `mfa` given `world`.

  `{:owned, subject_id}` when a subject owns the MFA (binding > surface +
  lexical tiebreak). `:shared` when no subject owns it.
  """
  @spec subject_for_mfa(mfa_tuple(), world()) :: {:owned, String.t()} | :shared
  def subject_for_mfa({mod, fun, arity} = mfa, world)
      when is_atom(mod) and is_atom(fun) and is_integer(arity) and is_map(world) do
    case owner_by_binding(mfa, Map.get(world, :subjects, [])) do
      {:ok, id} ->
        {:owned, id}

      :error ->
        case owner_by_surface(mfa, world) do
          {:ok, id} -> {:owned, id}
          :error -> :shared
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Walk
  # ---------------------------------------------------------------------------

  defp walk(mfa, subject, world, acc) do
    cond do
      MapSet.member?(acc.visited, mfa) ->
        acc

      not in_project?(mfa, world) ->
        acc

      true ->
        acc = %{acc | visited: MapSet.put(acc.visited, mfa)}

        case subject_for_mfa(mfa, world) do
          {:owned, id} when id == subject.id ->
            acc = %{acc | owned: [mfa | acc.owned]}
            recurse_callees(mfa, subject, world, acc)

          {:owned, other_id} ->
            %{acc | referenced: MapSet.put(acc.referenced, other_id)}

          :shared ->
            acc = %{acc | shared: [mfa | acc.shared]}
            recurse_callees(mfa, subject, world, acc)
        end
    end
  end

  defp recurse_callees(mfa, subject, world, acc) do
    callees = Map.get(world.tracer_edges, mfa, [])
    Enum.reduce(callees, acc, fn callee, acc -> walk(callee, subject, world, acc) end)
  end

  defp in_project?({mod, _fun, _arity}, world) do
    case Map.get(world, :in_project?) do
      nil -> true
      %MapSet{} = set -> MapSet.member?(set, mod)
      fun when is_function(fun, 1) -> fun.(mod)
    end
  end

  # ---------------------------------------------------------------------------
  # Starting MFAs (resolve binding strings on this subject)
  # ---------------------------------------------------------------------------

  defp starting_mfas(%{impl_bindings: bindings}) when is_list(bindings) do
    bindings
    |> Enum.flat_map(&parse_binding_mfa/1)
  end

  defp starting_mfas(_), do: []

  defp parse_binding_mfa(binding) when is_binary(binding) do
    case String.split(binding, "/") do
      [prefix, arity_str] ->
        case Integer.parse(arity_str) do
          {arity, ""} ->
            case String.split(prefix, ".") do
              parts when length(parts) >= 2 ->
                {mod_parts, [fun]} = Enum.split(parts, -1)
                mod = Module.concat(mod_parts)
                [{mod, String.to_atom(fun), arity}]

              _ ->
                []
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp parse_binding_mfa(_), do: []

  # ---------------------------------------------------------------------------
  # Ownership — binding
  # ---------------------------------------------------------------------------

  defp owner_by_binding(mfa, subjects) do
    Enum.find_value(subjects, :error, fn subject ->
      bindings = Map.get(subject, :impl_bindings, [])

      if Enum.any?(bindings, fn b -> parse_binding_mfa(b) == [mfa] end) do
        {:ok, subject.id}
      else
        nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Ownership — surface + lexical tiebreak
  # ---------------------------------------------------------------------------

  defp owner_by_surface({mod, _fun, _arity}, world) do
    subjects = Map.get(world, :subjects, [])
    manifest = Map.get(world, :manifest)

    source_paths = source_paths_for(mod, manifest)

    case source_paths do
      [] ->
        :error

      _ ->
        candidates =
          subjects
          |> Enum.filter(fn subject ->
            surface = Map.get(subject, :surface, [])
            Enum.any?(surface, fn entry -> Enum.any?(source_paths, &paths_match?(&1, entry)) end)
          end)
          |> Enum.map(& &1.id)
          |> Enum.sort()

        case candidates do
          [] -> :error
          [id | _] -> {:ok, id}
        end
    end
  end

  defp source_paths_for(mod, manifest) do
    from_manifest =
      if is_map(manifest) do
        Manifest.sources_for(manifest, mod)
      else
        []
      end

    from_manifest
    |> case do
      [] -> infer_source_path(mod)
      paths -> paths
    end
    |> List.wrap()
    |> Enum.map(&normalize_path/1)
  end

  defp infer_source_path(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        case mod.module_info(:compile)[:source] do
          source when is_list(source) -> [List.to_string(source)]
          source when is_binary(source) -> [source]
          _ -> []
        end

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp paths_match?(source_path, surface_entry) do
    source = to_string(source_path) |> String.trim_leading("./")
    entry = to_string(surface_entry) |> String.trim_leading("./")

    source == entry or
      String.ends_with?(source, "/" <> entry) or
      String.ends_with?(entry, "/" <> source)
  end

  defp normalize_path(path) when is_binary(path) do
    path |> to_string() |> String.trim_leading("./")
  end

  defp normalize_path(other), do: other
end
