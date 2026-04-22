defmodule SpecLedEx.Realization.Typespecs do
  # covers: specled.expanded_behavior_tier.typespecs_hashes_spec_and_type
  # covers: specled.expanded_behavior_tier.typespecs_drift_finding
  @moduledoc """
  Fourth realization tier. Hashes a module's `@spec` / `@type` declarations
  independently of function bodies, so that a typespec-only change produces a
  targeted drift finding with `tier: :typespecs` rather than being absorbed by
  the `expanded_behavior` hash.

  `hash/2` pulls the MFA's `@spec` list via `Code.Typespec.fetch_specs/1` and
  the module's `@type`/`@typep`/`@opaque` declarations via
  `Code.Typespec.fetch_types/1`. Declarations are sorted lexicographically on
  their serialized form before hashing to guarantee that declaration order in
  source does not induce drift.

  Missing debug_info degrades the same way as `expanded_behavior`: the tier
  emits `detector_unavailable (reason: :debug_info_stripped)` for the module
  and returns no hash.
  """

  alias SpecLedEx.Compiler.Context
  alias SpecLedEx.Realization.{Binding, Canonical, HashStore}

  @tier "typespecs"
  @drift_code "branch_guard_realization_drift"
  @dangling_code "branch_guard_dangling_binding"
  @detector_unavailable_code "detector_unavailable"

  @type binding_ref :: %{
          subject_id: String.t(),
          requirement_id: String.t() | nil,
          mfa: String.t()
        }

  @type hash_result ::
          {:ok, binary()}
          | {:error, {:debug_info_stripped, module()}}
          | {:error, {:not_found, map()}}

  @doc """
  Hashes the sorted `@spec` + `@type` declarations attributable to a single
  MFA binding.

  For an `MFA` binding, the hash input is:

    * the sorted list of `@spec` declarations with matching `{fun, arity}`,
    * the sorted list of all module-level `@type`/`@typep`/`@opaque`
      declarations (a typespec references types; a type change can affect any
      spec that references it, so the module's type declarations are included
      in the hash).

  Returns `{:error, {:debug_info_stripped, module}}` when the module loaded
  but typespec metadata is absent (the `@compile {:no_debug_info, true}`
  path), and `{:error, {:not_found, details}}` when the MFA cannot be
  resolved.
  """
  @spec hash(String.t(), keyword()) :: hash_result()
  def hash(mfa_string, _opts \\ []) when is_binary(mfa_string) do
    with {:ok, {mod, fun, arity}} <- parse_mfa(mfa_string),
         {:module, ^mod} <- Code.ensure_loaded(mod),
         :ok <- ensure_debug_info(mod) do
      specs = specs_for(mod, fun, arity)
      types = types_for(mod)
      input = {:__spec_typespecs__, mfa_string, canonical_list(specs), canonical_list(types)}
      {:ok, Canonical.hash(input)}
    else
      {:error, {:debug_info_stripped, mod}} ->
        {:error, {:debug_info_stripped, mod}}

      {:error, :invalid_mfa} ->
        {:error, {:not_found, %{mfa: mfa_string, reason: :invalid_mfa}}}

      {:error, _reason} ->
        {:error, {:not_found, %{mfa: mfa_string, searched: [:beam]}}}
    end
  end

  @doc """
  Runs the typespecs tier for a list of bindings.

  Emits `branch_guard_realization_drift` with `tier: :typespecs` on mismatch
  against the committed hash, `branch_guard_dangling_binding` on unresolvable
  MFA, and `detector_unavailable (reason: debug_info_stripped)` once per
  module whose debug_info is missing.
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
              "typespecs tier does not support umbrella apps in v1. " <>
                "Re-run per umbrella child app or wait for v1.1."
          }
        ]

      true ->
        root = Keyword.get(opts, :root, File.cwd!())
        store = HashStore.read(root)

        {findings, _reported} =
          Enum.reduce(bindings, {[], MapSet.new()}, fn binding, {acc, reported} ->
            {bfindings, reported} = check_binding(binding, context, store, reported)
            {acc ++ bfindings, reported}
          end)

        findings
    end
  end

  defp check_binding(%{mfa: mfa} = binding, _context, store, reported) do
    case hash(mfa) do
      {:ok, current} ->
        findings =
          case HashStore.fetch(store, @tier, mfa) do
            nil -> []
            committed when committed == current -> []
            _ -> [drift_finding(binding, current)]
          end

        {findings, reported}

      {:error, {:debug_info_stripped, mod}} ->
        if MapSet.member?(reported, mod) do
          {[], reported}
        else
          {[detector_unavailable_finding(binding, mod)], MapSet.put(reported, mod)}
        end

      {:error, {:not_found, details}} ->
        {[dangling_finding(binding, details)], reported}
    end
  end

  defp drift_finding(binding, current) do
    %{
      "code" => @drift_code,
      "tier" => @tier,
      "subject_id" => binding.subject_id,
      "requirement_id" => Map.get(binding, :requirement_id),
      "mfa" => binding.mfa,
      "current_hash" => Base.encode16(current, case: :lower),
      "message" =>
        "typespecs hash for #{binding.mfa} differs from committed value " <>
          "(subject=#{binding.subject_id})"
    }
  end

  defp dangling_finding(binding, details) do
    %{
      "code" => @dangling_code,
      "tier" => @tier,
      "subject_id" => binding.subject_id,
      "requirement_id" => Map.get(binding, :requirement_id),
      "mfa" => binding.mfa,
      "message" =>
        "Declared typespecs binding #{binding.mfa} is not defined " <>
          "(subject=#{binding.subject_id}, tier=#{@tier}). " <>
          "Update realized_by or restore the function. " <>
          "Searched: #{inspect(Map.get(details, :searched, [:beam]))}"
    }
  end

  defp detector_unavailable_finding(binding, mod) do
    %{
      "code" => @detector_unavailable_code,
      "reason" => "debug_info_stripped",
      "tier" => @tier,
      "subject_id" => binding.subject_id,
      "module" => inspect(mod),
      "message" =>
        "typespecs cannot hash #{inspect(mod)}: beam has no debug_info " <>
          "(likely @compile {:no_debug_info, true}). Subject not considered drifted on this tier."
    }
  end

  defp parse_mfa(mfa_string) do
    case Binding.parse(mfa_string) do
      {:ok, {mod, fun, arity}} -> {:ok, {mod, fun, arity}}
      {:ok, {:module, _}} -> {:error, :invalid_mfa}
      {:error, :invalid_mfa, _} -> {:error, :invalid_mfa}
    end
  end

  defp ensure_debug_info(mod) do
    case :code.which(mod) do
      path when is_list(path) or is_binary(path) ->
        binary =
          case :code.get_object_code(mod) do
            {^mod, bin, _} -> bin
            :error -> File.read!(to_string(path))
          end

        case :beam_lib.chunks(binary, [:debug_info]) do
          {:ok, {^mod, chunks}} ->
            case List.keyfind(chunks, :debug_info, 0) do
              {:debug_info, :none} -> {:error, {:debug_info_stripped, mod}}
              {:debug_info, {:debug_info_v1, _, :none}} -> {:error, {:debug_info_stripped, mod}}
              {:debug_info, {:debug_info_v1, _, _}} -> :ok
              _ -> {:error, {:debug_info_stripped, mod}}
            end

          _ ->
            {:error, {:debug_info_stripped, mod}}
        end

      _ ->
        {:error, {:debug_info_stripped, mod}}
    end
  end

  defp specs_for(mod, fun, arity) do
    case Code.Typespec.fetch_specs(mod) do
      {:ok, specs} ->
        specs
        |> Enum.filter(fn {{f, a}, _asts} -> f == fun and a == arity end)
        |> Enum.flat_map(fn {{f, a}, asts} -> Enum.map(asts, fn ast -> {f, a, ast} end) end)

      _ ->
        []
    end
  end

  defp types_for(mod) do
    case Code.Typespec.fetch_types(mod) do
      {:ok, types} ->
        Enum.map(types, fn {kind, {name, ast, vars}} -> {kind, name, ast, vars} end)

      _ ->
        []
    end
  end

  # Sort by serialized form so declaration order in source cannot induce drift.
  defp canonical_list(items) do
    items
    |> Enum.map(&strip_typespec_meta/1)
    |> Enum.sort_by(&:erlang.term_to_binary(&1, [:deterministic, minor_version: 2]))
  end

  # Erlang abstract forms used by typespecs carry :line metadata (either an
  # integer or a `{line, column}` tuple) in the second tuple position. Strip
  # every such anno recursively so whitespace/line shifts above a declaration
  # do not flip the hash. We also keep 4-tuple forms (`{kind, anno, name,
  # args}`) — common in `{:type, anno, :fun, [...]}` nodes.
  defp strip_typespec_meta({kind, name, ast, vars})
       when is_atom(kind) and is_atom(name) and is_list(vars) and
              kind in [:type, :typep, :opaque] do
    {kind, name, strip_typespec_meta(ast), Enum.map(vars, &strip_typespec_meta/1)}
  end

  defp strip_typespec_meta({fun, arity, ast})
       when is_atom(fun) and is_integer(arity) do
    {fun, arity, strip_typespec_meta(ast)}
  end

  defp strip_typespec_meta({kind, _anno, name, args})
       when is_atom(kind) and is_atom(name) and is_list(args) do
    {kind, 0, name, Enum.map(args, &strip_typespec_meta/1)}
  end

  defp strip_typespec_meta({kind, _anno, args}) when is_atom(kind) and is_list(args) do
    {kind, 0, Enum.map(args, &strip_typespec_meta/1)}
  end

  defp strip_typespec_meta({kind, _anno, arg}) when is_atom(kind) do
    {kind, 0, strip_typespec_meta(arg)}
  end

  defp strip_typespec_meta(list) when is_list(list), do: Enum.map(list, &strip_typespec_meta/1)
  defp strip_typespec_meta({a, b}), do: {strip_typespec_meta(a), strip_typespec_meta(b)}
  defp strip_typespec_meta(other), do: other
end
