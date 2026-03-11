defmodule SpecLedEx.Json do
  @moduledoc false

  alias Jason.OrderedObject

  def read(path) do
    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end
    else
      %{}
    end
  end

  def encode_to_iodata!(data) do
    data
    |> canonicalize()
    |> Jason.encode_to_iodata!(pretty: true)
  end

  def write!(path, data) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    encoded = encode_to_iodata!(data)
    binary = IO.iodata_to_binary(encoded)

    if File.exists?(path) and File.read!(path) == binary do
      :unchanged
    else
      File.write!(path, binary)
      :written
    end
  end

  defp canonicalize(%OrderedObject{values: values}) do
    values
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> OrderedObject.new()
  end

  defp canonicalize(%{__struct__: _} = value) do
    value
    |> Map.from_struct()
    |> canonicalize()
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {to_string(key), canonicalize(item)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> OrderedObject.new()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
