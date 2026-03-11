defmodule SpecLedEx.VerificationStrength do
  @moduledoc false

  @levels ~w(claimed linked executed)
  @default "claimed"
  @ranks Enum.with_index(@levels) |> Map.new()

  def levels, do: @levels

  def default, do: @default

  def valid?(value), do: value in @levels

  def normalize(nil), do: {:ok, nil}
  def normalize(value) when value in @levels, do: {:ok, value}
  def normalize(_value), do: {:error, "must be one of: #{Enum.join(@levels, ", ")}"}

  def normalize!(value) do
    case normalize(value) do
      {:ok, normalized} -> normalized
      {:error, message} -> raise ArgumentError, message
    end
  end

  def compare(left, right) when left in @levels and right in @levels do
    cond do
      @ranks[left] < @ranks[right] -> :lt
      @ranks[left] > @ranks[right] -> :gt
      true -> :eq
    end
  end

  def meets_minimum?(actual, minimum) when actual in @levels and minimum in @levels do
    compare(actual, minimum) in [:eq, :gt]
  end
end
