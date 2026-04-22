defmodule SpecLedEx.Realization.Canonical do
  @moduledoc """
  Canonicalizes ASTs for deterministic hashing.

  `normalize/1` strips line/column metadata, sorts attribute lists that are
  order-insensitive by semantics (`@behaviour`, `@derive`, `@spec`), and α-renames
  locally-bound variables so that cosmetic refactors (whitespace, variable
  renames, line shifts) produce byte-equal hashes.

  The α-rename guard is deliberately narrow. Reserved identifiers
  (`__MODULE__`, `__CALLER__`, `__ENV__`, `__DIR__`, `__STACKTRACE__`,
  `__block__`) are **never** rewritten. Only variables whose context is `nil` or
  `Elixir` are rewritten — other contexts (macro hygiene) are left intact to
  avoid collapsing meaningful differences.

  `hash/1` serializes a normalized AST with `:erlang.term_to_binary/2` using
  `[:deterministic, minor_version: 2]` per the
  `specled.decision.deterministic_hashing` ADR, then SHA-256's the bytes.
  """

  @reserved_idents [
    :__MODULE__,
    :__CALLER__,
    :__ENV__,
    :__DIR__,
    :__STACKTRACE__,
    :__block__,
    :__aliases__
  ]

  @sortable_attrs [:behaviour, :derive, :spec]

  @doc "Returns the list of reserved identifiers that are never α-renamed."
  @spec reserved_identifiers() :: [atom()]
  def reserved_identifiers, do: @reserved_idents

  @doc """
  Canonicalizes an AST.

  Steps:
    1. Strip metadata on every node (drops `:line`, `:column`, etc).
    2. Sort `@behaviour`/`@derive`/`@spec` attribute lists.
    3. α-rename locally-bound variables to stable positional names (`v1`, `v2`,
       ...) subject to the reserved-identifier / context guard.
  """
  @spec normalize(Macro.t()) :: Macro.t()
  def normalize(ast) do
    ast
    |> strip_meta()
    |> sort_attr_lists()
    |> alpha_rename()
  end

  @doc """
  Hashes a canonicalized AST with a stable 256-bit SHA digest.

  Uses `:erlang.term_to_binary/2` with `[:deterministic, minor_version: 2]` to
  guarantee the byte encoding is identical across OTP minor bumps and OSes.
  """
  @spec hash(Macro.t()) :: binary()
  def hash(normalized_ast) do
    bytes = :erlang.term_to_binary(normalized_ast, [:deterministic, minor_version: 2])
    :crypto.hash(:sha256, bytes)
  end

  defp strip_meta({form, _meta, args}) when is_list(args) do
    {form, [], Enum.map(args, &strip_meta/1)}
  end

  defp strip_meta({form, _meta, ctx}) when is_atom(ctx) do
    {form, [], ctx}
  end

  defp strip_meta({left, right}) do
    {strip_meta(left), strip_meta(right)}
  end

  defp strip_meta(list) when is_list(list) do
    Enum.map(list, &strip_meta/1)
  end

  defp strip_meta(other), do: other

  defp sort_attr_lists({:@, meta, [{attr_name, inner_meta, [list]}]} = node)
       when attr_name in @sortable_attrs and is_list(list) do
    sorted = list |> Enum.map(&strip_meta/1) |> Enum.sort_by(&inspect/1)
    {:@, meta, [{attr_name, inner_meta, [sorted]}]}
  rescue
    _ -> node
  end

  defp sort_attr_lists({form, meta, args}) when is_list(args) do
    {form, meta, Enum.map(args, &sort_attr_lists/1)}
  end

  defp sort_attr_lists({left, right}) do
    {sort_attr_lists(left), sort_attr_lists(right)}
  end

  defp sort_attr_lists(list) when is_list(list) do
    Enum.map(list, &sort_attr_lists/1)
  end

  defp sort_attr_lists(other), do: other

  defp alpha_rename(ast) do
    {renamed, _acc} = Macro.prewalk(ast, %{mapping: %{}, counter: 0}, &rename_node/2)
    renamed
  end

  defp rename_node({name, meta, ctx} = node, acc)
       when is_atom(name) and is_atom(ctx) and is_list(meta) do
    cond do
      name in @reserved_idents ->
        {node, acc}

      ctx not in [nil, Elixir] ->
        {node, acc}

      String.starts_with?(Atom.to_string(name), "_") ->
        {node, acc}

      true ->
        case Map.fetch(acc.mapping, {name, ctx}) do
          {:ok, renamed} ->
            {{renamed, meta, ctx}, acc}

          :error ->
            counter = acc.counter + 1
            renamed = String.to_atom("v#{counter}")
            acc = %{acc | mapping: Map.put(acc.mapping, {name, ctx}, renamed), counter: counter}
            {{renamed, meta, ctx}, acc}
        end
    end
  end

  defp rename_node(other, acc), do: {other, acc}
end
