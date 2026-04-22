defmodule SpecLedEx.Compiler.Manifest do
  @moduledoc """
  Wraps `Mix.Compilers.Elixir.read_manifest/1`.

  The compile manifest is the seam where module → source-file relationships live.
  Parsing it ourselves would be a maintenance trap: the format is an internal OTP
  binary term whose shape changes across Elixir minor versions. Instead, this module
  delegates to the stdlib reader and exposes a small helper for extracting source
  paths per module.

  If a future Elixir minor version changes the manifest format, failure surfaces as
  a test error (the `manifest_integration_test` is the canary), not a silent misread.
  """

  @doc """
  Reads the compile manifest at `path`.

  Delegates to `Mix.Compilers.Elixir.read_manifest/1` and normalizes the result
  to a map from module atom → module-descriptor tuple. Newer Elixir versions
  return a `{modules_map, sources_map}` tuple; we unwrap the modules half so
  callers (and `sources_for/2`) see a stable map shape. The sources half is
  reachable via `sources_map/1`.

  Returns an empty map when the manifest is missing or unreadable.
  """
  @spec load(Path.t()) :: map()
  def load(path) when is_binary(path) do
    if File.exists?(path) do
      try do
        normalize(Mix.Compilers.Elixir.read_manifest(path))
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  def load(_), do: %{}

  defp normalize({modules_map, _sources_map}) when is_map(modules_map), do: modules_map
  defp normalize(map) when is_map(map), do: map
  defp normalize(_), do: %{}

  @doc """
  Returns the list of source files for a given module, or `[]` if the module is
  absent from the manifest.
  """
  @spec sources_for(map(), module()) :: [Path.t()]
  def sources_for(manifest, module) when is_map(manifest) and is_atom(module) do
    case Map.get(manifest, module) do
      {:module, _kind, sources, _, _, _} when is_list(sources) -> sources
      {:module, _kind, sources, _, _, _, _} when is_list(sources) -> sources
      tuple when is_tuple(tuple) -> extract_sources_from_tuple(tuple)
      _ -> []
    end
  end

  def sources_for(_, _), do: []

  defp extract_sources_from_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.find(fn v -> is_list(v) and Enum.all?(v, &is_binary/1) end)
    |> case do
      nil -> []
      list -> list
    end
  end
end
