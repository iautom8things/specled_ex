defmodule SpecLedEx.Config.Realization do
  @moduledoc """
  Config section for realization tiers (S2+).

  Placeholder for v1: no user-facing toggles land in S2 beyond the default
  `api_boundary` tier opt-in. Later tiers (implementation, expanded_behavior, use,
  typespecs) will extend this section with `enabled_tiers` and per-tier settings;
  `hasher_version` is intentionally **not** a user-config key (see
  `specled.binding.hasher_version_internal`).
  """

  defstruct enabled_tiers: [:api_boundary]

  @type t :: %__MODULE__{
          enabled_tiers: [atom()]
        }

  @doc "Returns defaults: only `api_boundary` is enabled."
  @spec defaults() :: t()
  def defaults, do: %__MODULE__{}

  @doc """
  Parses a raw YAML-derived map. Unknown keys are ignored silently; unknown tier
  names drop with a diagnostic.
  """
  @spec parse(map()) :: {t(), [String.t()]}
  def parse(input) when is_map(input) do
    allowed = ~w(api_boundary implementation expanded_behavior use typespecs)a

    tiers_raw =
      Map.get(input, "enabled_tiers", Map.get(input, :enabled_tiers, []))

    {valid, diagnostics} =
      Enum.reduce(List.wrap(tiers_raw), {[], []}, fn tier, {valid, diags} ->
        atom =
          cond do
            is_atom(tier) -> tier
            is_binary(tier) -> String.to_atom(tier)
            true -> nil
          end

        if atom in allowed do
          {[atom | valid], diags}
        else
          {valid, ["realization.enabled_tiers rejected: #{inspect(tier)}" | diags]}
        end
      end)

    tiers = if valid == [], do: [:api_boundary], else: Enum.uniq(Enum.reverse(valid))

    {%__MODULE__{enabled_tiers: tiers}, Enum.reverse(diagnostics)}
  end

  def parse(_), do: {defaults(), []}
end
