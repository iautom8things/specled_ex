defmodule SpecLedEx.Realization.Binding do
  @moduledoc """
  Resolves a declared `"Mod.fun/arity"` binding to its AST.

  Precedence (see `specled.decision.beam_first_binding_resolution`):

    1. `Code.ensure_loaded/1` on the target module.
    2. If loaded and `function_exported?/3`, extract the function clauses from
       beam `debug_info` and return `{:ok, ast}`.
    3. Fall back to source-AST lookup: locate the source via the compile
       manifest (or a provided path), parse the file, extract the `def` clauses.
    4. On complete miss, return `{:error, :not_found, details}` with the
       declared MFA and search paths — the caller translates this to a
       `branch_guard_dangling_binding` finding.

  A binding string may optionally name a module only (`"MyModule"`), in which
  case resolution verifies the module is loadable and returns the module atom
  wrapped in `{:ok, {:module, Module}}`. Tier-specific semantics decide what to
  do with module-only bindings.
  """

  alias SpecLedEx.Compiler.{Context, Manifest}

  @type mfa_ref :: {module(), atom(), non_neg_integer()}
  @type resolution ::
          {:ok, Macro.t()}
          | {:ok, {:module, module()}}
          | {:error, :not_found, map()}

  @doc """
  Parses an MFA string.

  Returns `{:ok, {mod, fun, arity}}` or `{:ok, {:module, mod}}` for module-only
  bindings. `{:error, :invalid_mfa, string}` for malformed input.
  """
  @spec parse(String.t()) ::
          {:ok, mfa_ref()} | {:ok, {:module, module()}} | {:error, :invalid_mfa, String.t()}
  def parse(binding) when is_binary(binding) and binding != "" do
    case String.split(binding, "/") do
      [prefix, arity_str] ->
        with {arity, ""} <- Integer.parse(arity_str),
             {:ok, {mod, fun}} <- split_mod_fun(prefix) do
          {:ok, {mod, fun, arity}}
        else
          _ -> {:error, :invalid_mfa, binding}
        end

      [module_only] ->
        if valid_module_name?(module_only) do
          case module_name_to_atom(module_only) do
            {:ok, mod} -> {:ok, {:module, mod}}
            :error -> {:error, :invalid_mfa, binding}
          end
        else
          {:error, :invalid_mfa, binding}
        end

      _ ->
        {:error, :invalid_mfa, binding}
    end
  end

  def parse(""), do: {:error, :invalid_mfa, ""}

  defp valid_module_name?(name) when is_binary(name) do
    parts = String.split(name, ".")

    parts != [] and
      Enum.all?(parts, fn part ->
        part != "" and String.match?(part, ~r/^[A-Z][A-Za-z0-9_]*$/)
      end)
  end

  defp split_mod_fun(prefix) do
    case String.split(prefix, ".") do
      parts when length(parts) >= 2 ->
        {module_parts, [fun_name]} = Enum.split(parts, -1)

        with {:ok, mod} <- module_name_to_atom(Enum.join(module_parts, ".")) do
          {:ok, {mod, String.to_atom(fun_name)}}
        end

      _ ->
        :error
    end
  end

  defp module_name_to_atom(name) do
    try do
      {:ok, Module.concat([name])}
    rescue
      _ -> :error
    end
  end

  @doc """
  Resolves a binding string to its AST.

  Accepts an optional `%Context{}` used for source-fallback source-file
  discovery via the compile manifest.
  """
  @spec resolve(String.t(), Context.t() | nil) :: resolution()
  def resolve(binding_str, context \\ nil) do
    case parse(binding_str) do
      {:ok, {mod, fun, arity}} ->
        beam_or_source(binding_str, mod, fun, arity, context)

      {:ok, {:module, mod}} ->
        case Code.ensure_loaded(mod) do
          {:module, ^mod} -> {:ok, {:module, mod}}
          _ -> {:error, :not_found, %{mfa: binding_str, searched: [:beam]}}
        end

      {:error, :invalid_mfa, mfa} ->
        {:error, :not_found, %{mfa: mfa, reason: :invalid_mfa, searched: []}}
    end
  end

  defp beam_or_source(binding_str, mod, fun, arity, context) do
    searched = []

    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        if function_exported?(mod, fun, arity) or macro_fun_exported?(mod, fun, arity) do
          case extract_from_beam(mod, fun, arity) do
            {:ok, ast} ->
              {:ok, ast}

            :error ->
              source_fallback(binding_str, mod, fun, arity, context, [:beam_no_debug_info])
          end
        else
          source_fallback(binding_str, mod, fun, arity, context, [:beam_fn_missing])
        end

      _ ->
        source_fallback(binding_str, mod, fun, arity, context, [:module_not_loaded])
    end
    |> case do
      {:error, :not_found, details} ->
        {:error, :not_found,
         %{details | searched: Enum.uniq(details.searched ++ searched ++ [:beam, :source])}}

      other ->
        other
    end
  end

  defp macro_fun_exported?(mod, fun, arity) do
    try do
      macro_name = :"MACRO-#{fun}"
      function_exported?(mod, macro_name, arity + 1)
    rescue
      _ -> false
    end
  end

  defp extract_from_beam(mod, fun, arity) do
    with {:ok, binary} <- beam_binary_for(mod),
         {:ok, {^mod, chunks}} <- :beam_lib.chunks(binary, [:debug_info]),
         {:debug_info, {:debug_info_v1, backend, data}} <- List.keyfind(chunks, :debug_info, 0),
         {:ok, module_map} when is_map(module_map) <-
           backend.debug_info(:elixir_v1, mod, data, []) do
      find_clause_ast(module_map, fun, arity)
    else
      _ -> :error
    end
  end

  defp beam_binary_for(mod) do
    case :code.get_object_code(mod) do
      {^mod, binary, _filename} ->
        {:ok, binary}

      :error ->
        case :code.which(mod) do
          path when is_list(path) ->
            File.read(List.to_string(path))

          path when is_binary(path) ->
            File.read(path)

          _ ->
            :error
        end
    end
  end

  defp find_clause_ast(%{definitions: definitions}, fun, arity) do
    Enum.find_value(definitions, :error, fn
      {{^fun, ^arity}, _kind, _meta, clauses} when clauses != [] ->
        {:ok, clauses_ast(fun, arity, clauses)}

      _ ->
        nil
    end)
  end

  defp find_clause_ast(_, _, _), do: :error

  defp clauses_ast(fun, arity, clauses) do
    # Return a normalized representation: the list of clauses. Each clause is
    # `{meta, args, guards, body}`; we strip meta-level locations so downstream
    # canonicalization is straightforward.
    {fun, arity, Enum.map(clauses, fn {_meta, args, guards, body} -> {args, guards, body} end)}
  end

  defp source_fallback(binding_str, mod, fun, arity, context, attempts) do
    with {:ok, source_path} <- locate_source(mod, context),
         {:ok, ast} <- extract_from_source(source_path, mod, fun, arity) do
      {:ok, ast}
    else
      _ ->
        {:error, :not_found,
         %{
           mfa: binding_str,
           module: mod,
           function: fun,
           arity: arity,
           searched: attempts ++ [:source],
           source_paths: List.wrap(maybe_source_path(mod, context))
         }}
    end
  end

  defp maybe_source_path(mod, context) do
    case locate_source(mod, context) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  defp locate_source(mod, %Context{manifest: manifest}) when is_map(manifest) do
    case Manifest.sources_for(manifest, mod) |> List.first() do
      nil -> infer_source_path(mod)
      path -> {:ok, path}
    end
  end

  defp locate_source(mod, _), do: infer_source_path(mod)

  defp infer_source_path(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        case mod.module_info(:compile)[:source] do
          source when is_list(source) -> {:ok, List.to_string(source)}
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp extract_from_source(path, _mod, fun, arity) do
    case File.read(path) do
      {:ok, contents} ->
        case Code.string_to_quoted(contents) do
          {:ok, ast} -> find_def_in_ast(ast, fun, arity)
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp find_def_in_ast(ast, fun, arity) do
    ast
    |> Macro.prewalk([], fn node, acc ->
      case node do
        {kind, _, [{^fun, _, args} | _]} = def_node
        when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(args) and
               length(args) == arity ->
          {def_node, [def_node | acc]}

        # head with when-guard: `def fun(args) when guard`
        {kind, _, [{:when, _, [{^fun, _, args} | _]} | _]} = def_node
        when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(args) and
               length(args) == arity ->
          {def_node, [def_node | acc]}

        _ ->
          {node, acc}
      end
    end)
    |> case do
      {_ast, [def_node | _]} -> {:ok, def_node}
      {_ast, []} -> :error
    end
  end
end
