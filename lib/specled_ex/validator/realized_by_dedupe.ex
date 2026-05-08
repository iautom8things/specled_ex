defmodule SpecLedEx.Validator.RealizedByDedupe do
  @moduledoc """
  Single source of truth for `realized_by` cross-tier duplicate detection.

  Both `mix spec.validate`'s redundant-dup warning (via
  `SpecLedEx.Validator.RealizedByDedupCheck`) and the future
  `mix spec.dedup_realized_by` task call `duplicates/1` so the two surfaces
  cannot disagree on edge cases. See
  `specled.realized_by.dedup_check_shared_seam` and
  `specled.decision.realized_by_tier_implication` (Decision 7).

  The check is intentionally narrow: it reports entries that appear in both
  `api_boundary` and `implementation` on the same subject. The implication
  rule (`implementation` ⟹ `api_boundary`) means the api_boundary listing is
  redundant — the entry is already tracked under api_boundary via the
  one-way implication. Authors should remove the api_boundary line.

  Other tier pairs (`expanded_behavior`, `use`, `typespecs`) are orthogonal to
  the implication and are not reported by this helper.
  """

  @tier_pair {"api_boundary", "implementation"}

  @typedoc "An entry string as it appears under `realized_by`, after trimming."
  @type entry :: String.t()

  @typedoc "The cross-tier pair the duplicate spans."
  @type tier_pair :: {String.t(), String.t()}

  @doc """
  Returns the list of `{tier_pair, entry}` duplicates for the given subject.

  `subject` may be a parsed-subject map (`%{"meta" => %Meta{}, ...}`), a
  `%Meta{}` struct directly, or any plain map carrying a top-level
  `realized_by` (atom or string keyed). Entry strings are trimmed before
  the intersection is computed; the returned `entry` is the trimmed form.

  The returned list is sorted lexicographically by `entry` for deterministic
  output. Each duplicate is reported exactly once even if the entry appears
  multiple times within a single tier.

  Returns `[]` when no realized_by is present, when only one of the two
  tiers carries entries, or when the subject is malformed.
  """
  @spec duplicates(term()) :: [{tier_pair(), entry()}]
  def duplicates(subject) do
    realized_by = fetch_realized_by(subject)

    api_boundary = trimmed_entries(realized_by, "api_boundary")
    implementation = trimmed_entries(realized_by, "implementation")

    case {api_boundary, implementation} do
      {[], _} ->
        []

      {_, []} ->
        []

      {api, impl} ->
        api_set = MapSet.new(api)
        impl_set = MapSet.new(impl)

        MapSet.intersection(api_set, impl_set)
        |> Enum.sort()
        |> Enum.map(fn entry -> {@tier_pair, entry} end)
    end
  end

  @doc "Returns the tier pair this dedupe helper inspects."
  @spec tier_pair() :: tier_pair()
  def tier_pair, do: @tier_pair

  # --- realized_by extraction ---------------------------------------------
  #
  # Mirrors `SpecLedEx.Realization.EffectiveBinding.fetch_realized_by/1`'s
  # accepted shapes so callers can hand us either a parsed-subject map or a
  # bare meta/requirement struct.

  defp fetch_realized_by(nil), do: %{}

  defp fetch_realized_by(map) when is_map(map) do
    Map.get(map, :realized_by) ||
      Map.get(map, "realized_by") ||
      get_in_map(map, [:meta, :realized_by]) ||
      get_in_map(map, [:meta, "realized_by"]) ||
      get_in_map(map, ["meta", :realized_by]) ||
      get_in_map(map, ["meta", "realized_by"]) ||
      %{}
  end

  defp fetch_realized_by(_), do: %{}

  defp get_in_map(map, [key]) when is_map(map), do: Map.get(map, key)

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      next when is_map(next) -> get_in_map(next, rest)
      _ -> nil
    end
  end

  defp get_in_map(_, _), do: nil

  # --- entry trimming -----------------------------------------------------

  defp trimmed_entries(realized_by, tier) when is_map(realized_by) do
    case fetch_tier(realized_by, tier) do
      list when is_list(list) ->
        list
        |> Enum.flat_map(&normalize_entry/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp trimmed_entries(_, _), do: []

  defp fetch_tier(realized_by, tier) when is_binary(tier) do
    Map.get(realized_by, tier) ||
      case safe_existing_atom(tier) do
        nil -> nil
        atom -> Map.get(realized_by, atom)
      end
  end

  defp safe_existing_atom(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> nil
  end

  defp normalize_entry(entry) when is_binary(entry) do
    case String.trim(entry) do
      "" -> []
      trimmed -> [trimmed]
    end
  end

  defp normalize_entry(entry) when is_atom(entry) do
    entry |> Atom.to_string() |> normalize_entry()
  end

  defp normalize_entry(_), do: []
end
