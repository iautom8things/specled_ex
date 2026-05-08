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

  ## Bare-module union hashing

  `hash_module_head_union/2` and `hash_module_full_union/2` produce a single
  hash over the union of a module's public exports — used by api_boundary and
  implementation tier detectors when a `realized_by` entry names a module
  rather than an MFA. See `specled.decision.realized_by_tier_implication`.

  Discovery is **runtime-only** (`Module.__info__/1`). When the target
  module fails to load, both functions return `{:error, :not_loadable}` —
  the detector translates this to `branch_guard_dangling_binding` rather
  than seeding a stale source-AST hash.
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

  # ---------------------------------------------------------------------------
  # Bare-module union hashing
  # ---------------------------------------------------------------------------

  @doc """
  Hashes the union of a module's public function and macro **heads**.

  Used by the api_boundary detector when a `realized_by` entry names a module
  rather than an MFA. The hash input is the canonical envelope

      {:__module_head_union__, mod, sorted_exports}

  where `sorted_exports` is the list of `{kind, name, arity, head_ast}` tuples
  for every public function and macro on the module, sorted lexicographically
  by `{kind, name, arity}`. `head_ast` is a per-clause list of
  `{arg_pattern, guards}` extracted from BEAM debug_info and passed through
  `normalize/1` for stability under cosmetic refactors.

  `module_info/0` and `module_info/1` are excluded (BEAM-injected, not author
  surface). `__struct__/0` and `__struct__/1` (from `defstruct`) are included.

  Returns `{:ok, <sha256 binary>}` on success; `{:error, :not_loadable}` when
  the module cannot be loaded.
  """
  @spec hash_module_head_union(module(), keyword()) :: {:ok, binary()} | {:error, term()}
  def hash_module_head_union(mod, opts \\ []) when is_atom(mod) do
    with {:ok, exports} <- discover_module_exports(mod, opts) do
      entries =
        Enum.map(exports, fn {kind, name, arity} ->
          head_ast = head_ast_for_export(mod, kind, name, arity)
          {kind, name, arity, head_ast}
        end)

      envelope = {:__module_head_union__, mod, entries}
      {:ok, hash(envelope)}
    end
  end

  @doc """
  Hashes the union of a module's public function and macro **full** ASTs
  (head + guards + body).

  Used by the implementation detector when a `realized_by` entry names a
  module rather than an MFA. The hash input is the canonical envelope

      {:__module_full_union__, mod, sorted_exports}

  where each entry is `{kind, name, arity, full_ast}`. The envelope tag
  differs from the head-union tag, guaranteeing the head-union and full-union
  hashes for the same module are distinct bytes even on a degenerate
  module (e.g. one with no public exports).

  `module_info/0|1` are excluded; `__struct__/0|1` are included.

  Returns `{:ok, <sha256 binary>}` on success; `{:error, :not_loadable}` when
  the module cannot be loaded.

  Note: the closure walker does NOT seed from bare-module entries; helpers
  reachable only through a bare-module entry do not flow into this hash.
  """
  @spec hash_module_full_union(module(), keyword()) :: {:ok, binary()} | {:error, term()}
  def hash_module_full_union(mod, opts \\ []) when is_atom(mod) do
    with {:ok, exports} <- discover_module_exports(mod, opts) do
      entries =
        Enum.map(exports, fn {kind, name, arity} ->
          full_ast = full_ast_for_export(mod, kind, name, arity)
          {kind, name, arity, full_ast}
        end)

      envelope = {:__module_full_union__, mod, entries}
      {:ok, hash(envelope)}
    end
  end

  # Runtime-only export discovery via Module.__info__/1.
  #
  # Returns `{:ok, sorted_exports}` where each entry is `{kind, name, arity}`
  # with `kind` one of `:function | :macro`. Excludes `module_info/0|1`;
  # includes `__struct__/0|1`. Source-AST fallback is deliberately NOT used
  # — see `specled.decision.realized_by_tier_implication`.
  defp discover_module_exports(mod, _opts) when is_atom(mod) do
    case Code.ensure_loaded(mod) do
      {:module, ^mod} ->
        functions =
          mod.__info__(:functions)
          |> Enum.reject(fn {name, arity} ->
            name == :module_info and arity in [0, 1]
          end)
          |> Enum.map(fn {name, arity} -> {:function, name, arity} end)

        macros =
          mod.__info__(:macros)
          |> Enum.map(fn {name, arity} -> {:macro, name, arity} end)

        exports =
          (functions ++ macros)
          |> Enum.sort_by(fn {kind, name, arity} -> {kind, name, arity} end)

        {:ok, exports}

      _ ->
        {:error, :not_loadable}
    end
  end

  # Per-export head AST.
  #
  # Returns a per-clause list of normalized `{args, guards}` tuples — body is
  # excluded so that cosmetic body changes do not change the api_boundary
  # hash. If clause extraction from BEAM debug_info fails (e.g. function is
  # auto-generated with no debug entry), falls back to the export tuple
  # itself, which still flips the hash on arity / kind / name changes.
  defp head_ast_for_export(mod, kind, name, arity) do
    case extract_clauses(mod, kind, name, arity) do
      {:ok, clauses} ->
        clauses
        |> Enum.map(fn {args, guards, _body} ->
          {normalize(args), normalize(guards)}
        end)

      :error ->
        :no_debug_info
    end
  end

  # Per-export full AST. Includes args, guards, and body — body changes
  # flip the implementation hash. Same fallback as the head path.
  defp full_ast_for_export(mod, kind, name, arity) do
    case extract_clauses(mod, kind, name, arity) do
      {:ok, clauses} ->
        clauses
        |> Enum.map(fn {args, guards, body} ->
          {normalize(args), normalize(guards), normalize(body)}
        end)

      :error ->
        :no_debug_info
    end
  end

  # Pulls the list of `{args, guards, body}` clauses for an exported
  # function or macro from BEAM debug_info. Macros are stored in
  # debug_info under `:"MACRO-<name>"` with `arity + 1` (the implicit
  # `__CALLER__` arg).
  defp extract_clauses(mod, kind, name, arity) do
    {beam_name, beam_arity} =
      case kind do
        :macro -> {:"MACRO-#{name}", arity + 1}
        :function -> {name, arity}
      end

    with {:ok, binary} <- beam_binary_for(mod),
         {:ok, {^mod, chunks}} <- :beam_lib.chunks(binary, [:debug_info]),
         {:debug_info, {:debug_info_v1, backend, data}} <-
           List.keyfind(chunks, :debug_info, 0),
         {:ok, module_map} when is_map(module_map) <-
           backend.debug_info(:elixir_v1, mod, data, []) do
      case Map.fetch(module_map, :definitions) do
        {:ok, definitions} ->
          Enum.find_value(definitions, :error, fn
            {{^beam_name, ^beam_arity}, _kind, _meta, raw_clauses} when raw_clauses != [] ->
              {:ok,
               Enum.map(raw_clauses, fn {_meta, args, guards, body} -> {args, guards, body} end)}

            _ ->
              nil
          end)

        :error ->
          :error
      end
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
          path when is_list(path) -> File.read(List.to_string(path))
          path when is_binary(path) -> File.read(path)
          _ -> :error
        end
    end
  end
end
