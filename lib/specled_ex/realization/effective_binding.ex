defmodule SpecLedEx.Realization.EffectiveBinding do
  @moduledoc """
  Merges subject-level and requirement-level `realized_by` bindings per requirement.

  Rule (see `specled.realized_by.effective_binding_inherits_subject` and
  `specled.realized_by.effective_binding_requirement_replaces_tier`): per tier,
  the requirement value replaces the subject value if set; otherwise the subject
  value is used. Tiers not set by either layer are absent from the return value.

  Inputs are the normalized binding maps returned by `SpecLedEx.Schema.RealizedBy.validate/1`.
  Accepts either parsed schema structs (`%SpecLedEx.Schema.Meta{}`,
  `%SpecLedEx.Schema.Requirement{}`) or plain maps with a `:realized_by` /
  `"realized_by"` key.
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
    case Map.get(map, :realized_by, Map.get(map, "realized_by")) do
      nil -> %{}
      %{} = rb -> normalize_keys(rb)
      _ -> %{}
    end
  end

  defp extract_binding(_), do: %{}

  defp normalize_keys(rb) do
    Map.new(rb, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end
end
