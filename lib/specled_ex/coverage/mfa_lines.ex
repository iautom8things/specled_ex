defmodule SpecLedEx.Coverage.MfaLines do
  # covers: specled.coverage_capture.mfa_lines_index
  @moduledoc """
  Indexes per-MFA source line sets from BEAM abstract code for per-test
  coverage closure.

  `index/1` returns `%{module => fun_index | :no_debug_info}` where
  `fun_index` is `%{{fun, arity} => MapSet.t(line)}`. Line sets are derived
  from `:beam_lib.chunks(beam, [:abstract_code])` function-form clause
  annos — every line annotation reachable under a `{fun, arity}` form is
  collected so a per-test `lines_hit` record can intersect the MFA.

  Modules without abstract code (stripped debug info, unloadable BEAMs)
  map to `:no_debug_info` rather than an empty map: callers must surface
  that state, never silently treat those MFAs as uncovered via a
  file-level proxy.

  Production caller: `SpecLedEx.Review.CoverageClosure.build_v2/2` builds
  the index once per review over the subject's closure modules, then
  hands it to `CoverageTriangulation.per_test_requirement_reach/3`.
  """

  @type fun_key :: {atom(), non_neg_integer()}
  @type fun_index :: %{optional(fun_key()) => MapSet.t(pos_integer())}
  @type module_entry :: fun_index() | :no_debug_info
  @type index :: %{optional(module()) => module_entry()}

  @doc """
  Builds a per-module MFA line index for `modules`.

  Each module is resolved via `:code.get_object_code/1` and
  `:beam_lib.chunks/2` with `[:abstract_code]`. Failures (missing object
  code, missing abstract chunk, undecodable forms) yield `:no_debug_info`
  for that module only — other modules still index normally.
  """
  @spec index([module()]) :: index()
  def index(modules) when is_list(modules) do
    modules
    |> Enum.uniq()
    |> Map.new(fn mod -> {mod, index_module(mod)} end)
  end

  defp index_module(mod) when is_atom(mod) do
    with {^mod, binary, _path} <- :code.get_object_code(mod),
         {:ok, {^mod, chunks}} <- :beam_lib.chunks(binary, [:abstract_code]),
         {:abstract_code, {:raw_abstract_v1, forms}} <- List.keyfind(chunks, :abstract_code, 0) do
      forms
      |> Enum.reduce(%{}, fn
        {:function, _anno, name, arity, clauses}, acc when is_atom(name) and is_integer(arity) ->
          lines = collect_lines(clauses, MapSet.new())
          Map.put(acc, {name, arity}, lines)

        _, acc ->
          acc
      end)
    else
      _ -> :no_debug_info
    end
  end

  # Walk Erlang abstract forms, collecting every positive line annotation.
  # Annos may be bare integers, `{line, column}` tuples (OTP 24+), or
  # `erl_anno` lists.
  defp collect_lines(term, acc) when is_list(term),
    do: Enum.reduce(term, acc, &collect_lines/2)

  defp collect_lines({:function, anno, _name, _arity, clauses}, acc),
    do: collect_lines(clauses, add_anno(anno, acc))

  defp collect_lines({:clause, anno, pats, guards, body}, acc),
    do: collect_lines([pats, guards, body], add_anno(anno, acc))

  defp collect_lines({}, acc), do: acc

  defp collect_lines(term, acc) when is_tuple(term) do
    [head | tail] = Tuple.to_list(term)
    collect_lines(tail, maybe_add_anno(head, acc))
  end

  defp collect_lines(_term, acc), do: acc

  defp maybe_add_anno(anno, acc)
       when is_integer(anno) or is_list(anno) or is_tuple(anno),
       do: add_anno(anno, acc)

  defp maybe_add_anno(_anno, acc), do: acc

  defp add_anno(line, acc) when is_integer(line) and line > 0, do: MapSet.put(acc, line)

  defp add_anno({line, _col}, acc) when is_integer(line) and line > 0,
    do: MapSet.put(acc, line)

  defp add_anno(anno, acc) when is_list(anno) do
    line = :erl_anno.line(anno)
    if is_integer(line) and line > 0, do: MapSet.put(acc, line), else: acc
  rescue
    _ -> acc
  end

  defp add_anno(_anno, acc), do: acc
end
