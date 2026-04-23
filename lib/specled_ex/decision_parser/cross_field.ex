defmodule SpecLedEx.DecisionParser.CrossField do
  # covers: specled.decisions.cross_field_supersedes_replaces specled.decisions.cross_field_reverses_what specled.decisions.cross_field_affects_non_empty specled.decisions.cross_field_affects_resolve specled.decisions.cross_field_adr_append_only specled.decisions.cross_field_idempotent
  @moduledoc """
  Cross-field validation for decision frontmatter.

  Implements the seven rules in Appendix A of the spec-guardrails refined
  plan. Each rule runs against a parsed decision plus the current index
  (used for id resolution) and optional prior-state decisions (used for
  the ADR append-only rule R5).

  `validate/3` returns a list of error maps:

      %{rule: integer(), code: String.t(), severity: :error | :warning,
        message: String.t(), decision_id: String.t() | nil}

  Callers thread the errors into the parse-error path via
  `SpecLedEx.DecisionParser.parse_file/2`. The function is pure: repeated
  invocation with the same inputs produces the same output (idempotence
  property T8 #4).
  """

  alias SpecLedEx.Schema.Decision

  @type error :: %{
          rule: pos_integer(),
          code: String.t(),
          severity: :error | :warning,
          message: String.t(),
          decision_id: String.t() | nil
        }

  @weakening_types Decision.weakening_types()

  @doc """
  Runs every cross-field rule against `decision`.

  `opts` may carry `:prior_decisions` — a list of decision maps parsed
  from `prior_state.decisions`. Absent or `nil` disables rule R5
  (first-run bootstrap or shallow-clone case).
  """
  @spec validate(map(), map(), keyword()) :: [error()]
  def validate(decision, current_index, opts \\ []) do
    prior_decisions = Keyword.get(opts, :prior_decisions)

    []
    |> run_rule(:r1_supersedes_has_replaces, decision, current_index)
    |> run_rule(:r2_weakening_needs_reverses_what, decision, current_index)
    |> run_rule(:r3_affects_non_empty, decision, current_index)
    |> run_rule(:r4_affects_resolve, decision, current_index)
    |> run_rule_with_prior(:r5_adr_append_only, decision, prior_decisions)
    |> run_rule(:r7_missing_change_type, decision, current_index)
    |> Enum.reverse()
  end

  defp run_rule(errors, rule, decision, current_index) do
    case apply_rule(rule, decision, current_index) do
      nil -> errors
      error -> [error | errors]
    end
  end

  defp run_rule_with_prior(errors, _rule, _decision, nil), do: errors

  defp run_rule_with_prior(errors, :r5_adr_append_only, decision, prior_decisions) do
    case r5(decision, prior_decisions) do
      [] -> errors
      new_errors -> Enum.reduce(new_errors, errors, &[&1 | &2])
    end
  end

  # R1: change_type == supersedes → replaces non-empty AND every id resolves.
  defp apply_rule(:r1_supersedes_has_replaces, decision, current_index) do
    id = decision_id(decision)
    meta = meta(decision)

    if change_type(meta) == "supersedes" do
      replaces = list_field(meta, "replaces")
      resolvable_ids = resolvable_ids(current_index)

      cond do
        replaces == [] ->
          error(1, "cross_field/supersedes_missing_replaces", :error, id,
            "change_type `supersedes` requires a non-empty `replaces:` list")

        unresolved = first_unresolved(replaces, resolvable_ids) ->
          error(1, "cross_field/supersedes_unresolved_replaces", :error, id,
            "`replaces:` id #{inspect(unresolved)} does not resolve in current index")

        true ->
          nil
      end
    end
  end

  # R2: weakening change_type → reverses_what non-empty after trim.
  defp apply_rule(:r2_weakening_needs_reverses_what, decision, _current_index) do
    id = decision_id(decision)
    meta = meta(decision)
    ct = change_type(meta)

    if ct in @weakening_types do
      rw = meta |> Map.get("reverses_what", "") |> to_string() |> String.trim()

      if rw == "" do
        error(2, "cross_field/reverses_what_missing", :error, id,
          "change_type `#{ct}` requires a non-empty `reverses_what:` statement")
      end
    end
  end

  # R3: affects non-empty for every change_type except `clarifies`.
  defp apply_rule(:r3_affects_non_empty, decision, _current_index) do
    id = decision_id(decision)
    meta = meta(decision)
    ct = change_type(meta)
    affects = list_field(meta, "affects")

    if ct != nil and ct != "clarifies" and affects == [] do
      error(3, "cross_field/affects_empty", :error, id,
        "change_type `#{ct}` requires a non-empty `affects:` list")
    end
  end

  # R4: affects must reference existing ids in current_index (unless R6 carve-out).
  defp apply_rule(:r4_affects_resolve, decision, current_index) do
    id = decision_id(decision)
    meta = meta(decision)
    ct = change_type(meta)
    affects = list_field(meta, "affects")
    resolvable = resolvable_ids(current_index)

    cond do
      affects == [] ->
        nil

      ct == "deprecates" ->
        # R6: deprecates targets may be absent from current_index (that is the point).
        nil

      unresolved = first_unresolved(affects, resolvable) ->
        error(4, "cross_field/affects_unresolved", :error, id,
          "`affects:` id #{inspect(unresolved)} does not resolve in current index")

      true ->
        nil
    end
  end

  # R7: change_type absent on an ADR → warning.
  defp apply_rule(:r7_missing_change_type, decision, _current_index) do
    id = decision_id(decision)
    meta = meta(decision)

    if change_type(meta) == nil do
      error(7, "cross_field/missing_change_type", :warning, id,
        "ADR `#{id || "<unknown>"}` has no `change_type:` field; v1 will emit a warning at authorization lookup")
    end
  end

  # R5: ADR append-only. Compare head-side decision against prior-state version.
  # Structural fields (affects, change_type, reverses_what) must match byte-for-byte.
  # Status may only transition forward: accepted → deprecated | superseded.
  defp r5(decision, prior_decisions) do
    id = decision_id(decision)
    meta = meta(decision)

    case Enum.find(prior_decisions, fn d -> decision_id(d) == id end) do
      nil ->
        []

      prior ->
        prior_meta = meta(prior)
        []
        |> maybe_r5_field_drift(id, meta, prior_meta, "affects")
        |> maybe_r5_field_drift(id, meta, prior_meta, "change_type")
        |> maybe_r5_field_drift(id, meta, prior_meta, "reverses_what")
        |> maybe_r5_status_regression(id, meta, prior_meta)
    end
  end

  defp maybe_r5_field_drift(errors, id, meta, prior_meta, field) do
    head = Map.get(meta, field)
    base = Map.get(prior_meta, field)

    if head == base do
      errors
    else
      [
        error(
          5,
          "cross_field/adr_field_drift",
          :error,
          id,
          "accepted ADR `#{id || "<unknown>"}` cannot change `#{field}:` (base=#{inspect(base)}, head=#{inspect(head)})"
        )
        | errors
      ]
    end
  end

  defp maybe_r5_status_regression(errors, id, meta, prior_meta) do
    head = Map.get(meta, "status")
    base = Map.get(prior_meta, "status")

    if status_transition_allowed?(base, head) do
      errors
    else
      [
        error(
          5,
          "cross_field/adr_status_regression",
          :error,
          id,
          "ADR `#{id || "<unknown>"}` status transition #{inspect(base)} → #{inspect(head)} is not allowed (forward-only: accepted → deprecated | superseded)"
        )
        | errors
      ]
    end
  end

  defp status_transition_allowed?(same, same), do: true
  defp status_transition_allowed?("accepted", "deprecated"), do: true
  defp status_transition_allowed?("accepted", "superseded"), do: true
  defp status_transition_allowed?(_base, _head), do: false

  defp decision_id(decision) do
    case meta(decision) do
      nil -> nil
      meta -> Map.get(meta, "id")
    end
  end

  defp meta(%{"meta" => m}) when is_map(m), do: m
  defp meta(_), do: %{}

  defp change_type(meta) when is_map(meta) do
    case Map.get(meta, "change_type") do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      value -> to_string(value)
    end
  end

  defp list_field(meta, field) when is_map(meta) do
    case Map.get(meta, field) do
      nil -> []
      list when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp first_unresolved(ids, resolvable) do
    Enum.find(ids, fn id -> not MapSet.member?(resolvable, id) end)
  end

  defp resolvable_ids(current_index) do
    subject_ids = collect_ids(current_index["subjects"] || [], ["meta", "id"])
    requirement_ids = collect_requirement_ids(current_index["subjects"] || [])
    decision_ids = collect_ids(current_index["decisions"] || [], ["meta", "id"])

    MapSet.new(subject_ids ++ requirement_ids ++ decision_ids)
  end

  defp collect_ids(items, path) do
    items
    |> Enum.map(&get_in_nested(&1, path))
    |> Enum.reject(&is_nil/1)
  end

  defp collect_requirement_ids(subjects) do
    Enum.flat_map(subjects, fn subject ->
      subject
      |> Map.get("requirements", [])
      |> Enum.map(fn req ->
        cond do
          is_map(req) -> Map.get(req, "id") || Map.get(req, :id)
          true -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp get_in_nested(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{} -> {:cont, Map.get(acc, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  defp get_in_nested(_, _), do: nil

  defp error(rule, code, severity, decision_id, message) do
    %{
      rule: rule,
      code: code,
      severity: severity,
      message: message,
      decision_id: decision_id
    }
  end
end
