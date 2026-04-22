defmodule SpecLedEx.Schema.RealizedBy do
  @moduledoc """
  Zoi-backed schema for `realized_by` bindings on `spec-meta` and `spec-requirements`.

  Known tiers: `api_boundary`, `implementation`, `expanded_behavior`, `use`, `typespecs`.
  Each key is optional and carries a list of MFAs (string form `"Mod.fun/arity"`) or
  module atoms, per tier semantics. Unknown keys cause a validation error naming the
  offending key.
  """

  @tiers ~w(api_boundary implementation expanded_behavior use typespecs)

  @doc "Returns the list of allowed tier keys."
  @spec tiers() :: [String.t()]
  def tiers, do: @tiers

  @doc """
  Validates a map (YAML-derived) against the RealizedBy schema.

  Returns `{:ok, map}` where keys are string tier names and values are lists of
  binding strings. Rejects unknown keys with an error message naming them.
  """
  @spec validate(term()) :: {:ok, map()} | {:error, String.t()}
  def validate(value) when is_map(value) do
    normalized =
      Enum.reduce(value, %{}, fn {k, v}, acc ->
        Map.put(acc, to_string(k), v)
      end)

    unknown = Map.keys(normalized) -- @tiers

    cond do
      unknown != [] ->
        {:error,
         "unknown realized_by tier(s): #{unknown |> Enum.sort() |> Enum.join(", ")}"}

      true ->
        validate_tier_values(normalized)
    end
  end

  def validate(nil), do: {:ok, %{}}

  def validate(other),
    do: {:error, "realized_by must be a mapping, got #{inspect(other)}"}

  defp validate_tier_values(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {tier, value}, {:ok, acc} ->
      case normalize_tier_value(tier, value) do
        {:ok, list} -> {:cont, {:ok, Map.put(acc, tier, list)}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp normalize_tier_value(tier, value) when is_list(value) do
    case Enum.reduce_while(value, [], fn item, acc ->
           case normalize_item(item) do
             {:ok, string} -> {:cont, [string | acc]}
             {:error, message} -> {:halt, {:error, message}}
           end
         end) do
      {:error, message} -> {:error, "realized_by.#{tier}: #{message}"}
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp normalize_tier_value(tier, value),
    do: {:error, "realized_by.#{tier} must be a list, got #{inspect(value)}"}

  defp normalize_item(item) when is_binary(item), do: {:ok, item}
  defp normalize_item(item) when is_atom(item), do: {:ok, Atom.to_string(item)}

  defp normalize_item(other),
    do: {:error, "expected binding string, got #{inspect(other)}"}
end
