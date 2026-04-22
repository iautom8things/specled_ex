defmodule SpecLedEx.Realization.ApiBoundary do
  # covers: specled.compiler_context.orchestrators_take_context
  @moduledoc """
  First realization tier: hashes function heads + arg shapes per binding, emits
  `branch_guard_realization_drift` and `branch_guard_dangling_binding` findings.

  `hash/2` produces a hash stable under formatting changes, variable renames,
  and line-number shifts in the function body, but changing under arity, arg
  pattern shape, or literal default argument changes. Non-literal defaults
  (`\\\\ foo()`) do NOT change the hash — the same `:non_literal_default` rule
  that applies to defstruct defaults is applied uniformly here.

  `run/3` accepts a list of bindings (each `{subject_id, requirement_id, tier,
  mfa}`), a `%Context{}`, and opts. It returns findings in the shape used by
  `SpecLedEx.BranchCheck`.

  Umbrella graceful degrade: when `opts[:umbrella?]` is true, emits a single
  `detector_unavailable` finding with reason `:umbrella_unsupported` and skips
  without raising (v1 does not support umbrella apps; v1.1 will).
  """

  alias SpecLedEx.Compiler.Context
  alias SpecLedEx.Realization.{Binding, HashStore}

  @tier "api_boundary"
  @drift_code "branch_guard_realization_drift"
  @dangling_code "branch_guard_dangling_binding"
  @detector_unavailable_code "detector_unavailable"

  @type binding_ref :: %{
          subject_id: String.t(),
          requirement_id: String.t() | nil,
          mfa: String.t()
        }

  @doc """
  Hashes a resolved function head (the AST returned by `Binding.resolve/2`).

  Stable under whitespace, variable renames, and line shifts. Sensitive to
  arity, arg pattern structure, and literal default arguments. Non-literal
  defaults are replaced with `:non_literal_default` before hashing.
  """
  @spec hash(term(), keyword()) :: binary()
  def hash(resolved_ast, _opts \\ []) do
    canonical = canonicalize_head(resolved_ast)
    bytes = :erlang.term_to_binary(canonical, [:deterministic, minor_version: 2])
    :crypto.hash(:sha256, bytes)
  end

  @doc """
  Runs the api_boundary tier.

  Bindings is a list of `%{subject_id, requirement_id, mfa}` maps. Returns a
  list of finding maps (severity unassigned — caller passes them through
  `SpecLedEx.BranchCheck.Severity`).

  Opts:
    * `:umbrella?` — when true, emits a single `detector_unavailable` finding
      and skips binding work.
    * `:root` — project root for HashStore read (defaults to `File.cwd!/0`).
  """
  @spec run([binding_ref()], Context.t() | nil, keyword()) :: [map()]
  def run(bindings, context \\ nil, opts \\ []) do
    cond do
      Keyword.get(opts, :umbrella?, false) ->
        [
          %{
            "code" => @detector_unavailable_code,
            "reason" => "umbrella_unsupported",
            "message" =>
              "api_boundary tier does not support umbrella apps in v1. " <>
                "Re-run per umbrella child app or wait for v1.1."
          }
        ]

      true ->
        root = Keyword.get(opts, :root, File.cwd!())
        store = HashStore.read(root)
        Enum.flat_map(bindings, fn binding -> check_binding(binding, context, store) end)
    end
  end

  defp check_binding(%{mfa: mfa} = binding, context, store) do
    case Binding.resolve(mfa, context) do
      {:ok, {:module, _}} ->
        []

      {:ok, ast} ->
        current = hash(ast)

        case HashStore.fetch(store, @tier, mfa) do
          nil ->
            []

          committed when committed == current ->
            []

          _committed ->
            [
              %{
                "code" => @drift_code,
                "tier" => @tier,
                "subject_id" => binding.subject_id,
                "requirement_id" => Map.get(binding, :requirement_id),
                "mfa" => mfa,
                "message" =>
                  "api_boundary hash for #{mfa} differs from committed value " <>
                    "(subject=#{binding.subject_id})"
              }
            ]
        end

      {:error, :not_found, details} ->
        [
          %{
            "code" => @dangling_code,
            "tier" => @tier,
            "subject_id" => binding.subject_id,
            "requirement_id" => Map.get(binding, :requirement_id),
            "mfa" => mfa,
            "message" =>
              "Declared binding #{mfa} is not defined (subject=#{binding.subject_id}, " <>
                "tier=#{@tier}). Update realized_by or restore the function. " <>
                "Searched: #{inspect(Map.get(details, :searched, []))}"
          }
        ]
    end
  end

  defp canonicalize_head({fun, arity, clauses}) when is_atom(fun) and is_integer(arity) do
    normalized_clauses =
      clauses
      |> Enum.map(&normalize_clause/1)

    {:__spec_head__, fun, arity, normalized_clauses}
  end

  defp canonicalize_head({kind, _meta, args} = def_ast)
       when kind in [:def, :defp, :defmacro, :defmacrop] and is_list(args) do
    # Source-fallback AST: extract name, arity, arg pattern
    case head_from_def(def_ast) do
      {:ok, fun, arity, arg_pattern, defaults} ->
        {:__spec_head__, fun, arity, arg_pattern, defaults}

      :error ->
        # Fallback: strip meta and hope for the best
        def_ast |> strip_meta() |> List.wrap()
    end
  end

  defp canonicalize_head(other), do: strip_meta(other)

  defp normalize_clause({args, guards, _body}) do
    arg_pattern = Enum.map(args, &arg_shape/1)
    guard_shape = strip_meta(guards)
    {arg_pattern, guard_shape}
  end

  defp head_from_def({_kind, _meta, [{:when, _, [{fun, _, args} | _]} | _]}) when is_list(args) do
    pattern = Enum.map(args, &arg_shape/1)
    {:ok, fun, length(args), pattern, extract_defaults(args)}
  end

  defp head_from_def({_kind, _meta, [{fun, _, args} | _]}) when is_list(args) do
    pattern = Enum.map(args, &arg_shape/1)
    {:ok, fun, length(args), pattern, extract_defaults(args)}
  end

  defp head_from_def(_), do: :error

  defp extract_defaults(args) do
    Enum.flat_map(args, fn
      {:\\, _, [_arg, default]} -> [default_shape(default)]
      _ -> []
    end)
  end

  defp default_shape(ast) do
    if literal?(ast), do: strip_meta(ast), else: :non_literal_default
  end

  defp literal?(x) when is_number(x) or is_binary(x) or is_atom(x) or is_boolean(x), do: true
  defp literal?([]), do: true
  defp literal?(list) when is_list(list), do: Enum.all?(list, &literal?/1)
  defp literal?({a, b}), do: literal?(a) and literal?(b)
  defp literal?(_), do: false

  # Shape of an arg pattern: the AST structure without metadata, with nested
  # variable names replaced by `:__var__` so `%{key: val}` and `%{key: other}`
  # share a shape.
  defp arg_shape({:\\, _, [arg, _default]}), do: {:default, arg_shape(arg)}

  defp arg_shape({name, _meta, ctx}) when is_atom(name) and is_atom(ctx) do
    :__var__
  end

  defp arg_shape({form, _meta, args}) when is_list(args) do
    {form, Enum.map(args, &arg_shape/1)}
  end

  defp arg_shape({left, right}) do
    {arg_shape(left), arg_shape(right)}
  end

  defp arg_shape(list) when is_list(list) do
    Enum.map(list, &arg_shape/1)
  end

  defp arg_shape(literal), do: literal

  defp strip_meta({form, _meta, args}) when is_list(args) do
    {form, [], Enum.map(args, &strip_meta/1)}
  end

  defp strip_meta({form, _meta, ctx}) when is_atom(ctx), do: {form, [], ctx}
  defp strip_meta({l, r}), do: {strip_meta(l), strip_meta(r)}
  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta(other), do: other
end
