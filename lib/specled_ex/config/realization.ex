defmodule SpecLedEx.Config.Realization do
  @moduledoc """
  Config section for realization tier selection.

  ## YAML shape

      realization:
        enabled_tiers:
          - api_boundary
          - implementation
          - expanded_behavior
          - use
          - typespecs

  When `realization.enabled_tiers` is absent, `enabled_tiers` stays `nil` so the
  realization orchestrator owns its default tier list. An explicit empty list is
  preserved as `[]`, which opts out of every realization tier.

  `hasher_version` is intentionally **not** a user-config key (see
  `specled.binding.hasher_version_internal`).
  """

  @allowed_tiers ~w(api_boundary implementation expanded_behavior use typespecs)a
  @tier_by_name Map.new(@allowed_tiers, &{Atom.to_string(&1), &1})

  defstruct enabled_tiers: nil, rejected: []

  @type tier ::
          :api_boundary
          | :implementation
          | :expanded_behavior
          | :use
          | :typespecs

  @type t :: %__MODULE__{
          enabled_tiers: [tier()] | nil,
          rejected: [term()]
        }

  @doc "Returns defaults: no tier preference was provided."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc """
  Parses a raw YAML-derived map.

  Unknown keys are ignored silently. Unknown tier names are dropped from
  `enabled_tiers`, retained on `rejected`, and returned as diagnostics.
  """
  @spec parse(map()) :: {t(), [String.t()]}
  def parse(input) when is_map(input) do
    case fetch_enabled_tiers(input) do
      :missing ->
        {defaults(), []}

      {:ok, tiers_raw} ->
        parse_enabled_tiers(tiers_raw)
    end
  end

  def parse(_), do: {defaults(), []}

  defp fetch_enabled_tiers(input) do
    cond do
      Map.has_key?(input, "enabled_tiers") -> {:ok, Map.fetch!(input, "enabled_tiers")}
      Map.has_key?(input, :enabled_tiers) -> {:ok, Map.fetch!(input, :enabled_tiers)}
      true -> :missing
    end
  end

  defp parse_enabled_tiers(tiers_raw) do
    {tiers, rejected, diagnostics, _seen} =
      Enum.reduce(List.wrap(tiers_raw), {[], [], [], MapSet.new()}, fn tier,
                                                                       {tiers, rejected,
                                                                        diagnostics, seen} ->
        case normalize_tier(tier) do
          {:ok, normalized} ->
            if MapSet.member?(seen, normalized) do
              {tiers, rejected, diagnostics, seen}
            else
              {[normalized | tiers], rejected, diagnostics, MapSet.put(seen, normalized)}
            end

          :error ->
            {
              tiers,
              [tier | rejected],
              ["realization.enabled_tiers rejected: #{inspect(tier)}" | diagnostics],
              seen
            }
        end
      end)

    {
      %__MODULE__{enabled_tiers: Enum.reverse(tiers), rejected: Enum.reverse(rejected)},
      Enum.reverse(diagnostics)
    }
  end

  defp normalize_tier(tier) when is_atom(tier) and tier in @allowed_tiers do
    {:ok, tier}
  end

  defp normalize_tier(tier) when is_binary(tier) do
    case Map.fetch(@tier_by_name, tier) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp normalize_tier(_), do: :error
end
