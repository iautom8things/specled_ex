defmodule SpecLedEx.Realization.EffectiveBinding do
  @moduledoc """
  Merges subject-level and requirement-level `realized_by` bindings per requirement.

  Rule (see `specled.realized_by.effective_binding_inherits_subject` and
  `specled.realized_by.effective_binding_requirement_replaces_tier`): per tier,
  the requirement value replaces the subject value if set; otherwise the subject
  value is used. Tiers not set by either layer are absent from the return value.

  Inputs are the normalized binding maps returned by `SpecLedEx.Schema.RealizedBy.validate/1`.
  Accepts:
    * parsed schema structs (`%SpecLedEx.Schema.Meta{}`, `%SpecLedEx.Schema.Requirement{}`),
    * plain maps with a `:realized_by` / `"realized_by"` key, or
    * parsed-subject maps where `realized_by` is nested under `meta` (the
      shape produced by `SpecLedEx.Parser`). See
      `specled.decision.effective_binding_subject_meta_extraction`.
  """

  @doc """
  Returns the merged binding for a requirement on a subject.

  Returns an empty map when neither layer declares a binding.
  """
  @spec for_requirement(map(), map()) :: %{String.t() => [String.t()]}
  def for_requirement(subject, requirement) do
    subject_binding = extract_binding(subject)
    requirement_binding = extract_binding(requirement)

    Map.merge(subject_binding, requirement_binding)
  end

  defp extract_binding(nil), do: %{}

  defp extract_binding(map) when is_map(map) do
    case fetch_realized_by(map) do
      %{} = rb -> normalize_keys(rb)
      _ -> %{}
    end
  end

  defp extract_binding(_), do: %{}

  # covers: specled.realized_by.effective_binding_accepts_subject_shape
  # `Meta`/`Requirement` carry `realized_by` at the top level. A "subject"
  # map (the parser output for a whole `.spec.md` file) carries it under
  # `meta.realized_by`. Look there too so callers like `mix spec.triangle`
  # don't have to extract `meta` themselves before every call.
  defp fetch_realized_by(map) do
    Map.get(map, :realized_by) ||
      Map.get(map, "realized_by") ||
      get_in_map(map, [:meta, :realized_by]) ||
      get_in_map(map, [:meta, "realized_by"]) ||
      get_in_map(map, ["meta", :realized_by]) ||
      get_in_map(map, ["meta", "realized_by"])
  end

  defp get_in_map(map, [key]) when is_map(map), do: Map.get(map, key)

  defp get_in_map(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      next when is_map(next) -> get_in_map(next, rest)
      _ -> nil
    end
  end

  defp get_in_map(_, _), do: nil

  defp normalize_keys(rb) do
    Map.new(rb, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end
end
