defmodule SpecLedEx.Coverage.Paths do
  @moduledoc false

  # Shared module-to-source / repo-relative path identity for coverage
  # attribution joins. Call sites that previously inlined this must stay in
  # lockstep so record `:file`, formatter inventory, closure_files, and
  # triangle path joins compare equal identities.

  @doc false
  @spec to_binary(charlist() | binary()) :: binary()
  def to_binary(source) when is_list(source), do: List.to_string(source)
  def to_binary(source) when is_binary(source), do: source

  @doc false
  @spec repo_relative(term()) :: String.t() | nil
  def repo_relative(path) when is_binary(path) do
    root = File.cwd!() |> Path.expand()
    absolute = Path.expand(path, root)

    if String.starts_with?(absolute, root <> "/") do
      Path.relative_to(absolute, root)
    end
  end

  def repo_relative(_), do: nil

  @doc false
  @spec repo_relative_list(term()) :: [String.t()]
  def repo_relative_list(path) do
    case repo_relative(path) do
      nil -> []
      p -> [p]
    end
  end

  @doc false
  @spec module_source(module(), boolean()) :: String.t() | nil
  def module_source(module, load?) when is_atom(module) and is_boolean(load?) do
    if ensure_module(module, load?) do
      case module.module_info(:compile)[:source] do
        source when is_list(source) or is_binary(source) ->
          source |> to_binary() |> repo_relative()

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp ensure_module(module, false) do
    match?({_kind, _loaded_path}, :code.is_loaded(module))
  end

  defp ensure_module(module, true) do
    match?({:module, ^module}, Code.ensure_loaded(module))
  end
end
