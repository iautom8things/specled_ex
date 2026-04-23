defmodule SpecLedEx.Overlap do
  # covers: specled.overlap.duplicate_covers specled.overlap.must_stem_collision specled.overlap.within_subject_scope specled.overlap.findings_sorted specled.overlap.no_prior_state
  @moduledoc """
  Head-only semantic-overlap detector for authored `.spec/` content.

  `analyze/2` is a total pure function over `(subjects, requirements)`:

    * `subjects` — the head-side list of subject maps (raw index shape).
      Each subject carries its nested `"scenarios"` list and a `"meta"` map
      whose `"id"` field is the subject id. Only the scenarios on each
      subject are consulted — nested requirements are ignored by this
      detector because the flattened `requirements` list carries the
      `subject_id` needed for cross-checking.
    * `requirements` — the head-side flat list of requirements, each
      carrying `"subject_id"`, `"id"`, `"priority"`, and `"statement"`.

  The module consults nothing outside its two arguments — no state delta,
  no Git I/O, no file reads. `analyze/2` is pure by contract, a
  requirement of `specled.overlap.no_prior_state`.

  Emits two finding codes:

    * `overlap/duplicate_covers` at `:error` when two scenarios within the
      same subject both list the same requirement id in their `covers:`
      field.
    * `overlap/must_stem_collision` at `:error` when two `must`-priority
      requirements within the same subject share the same canonicalized
      MUST stem (the phrase starting at the leading modal verb, with
      punctuation stripped and case folded).

  Findings are sorted by `{subject_id, entity_id, code}` with `nil` keys
  treated as the empty string, matching the AppendOnly ordering contract.
  """

  @type severity :: :error

  @type finding :: %{
          code: String.t(),
          severity: severity(),
          subject_id: String.t() | nil,
          entity_id: String.t() | nil,
          message: String.t()
        }

  @doc """
  Returns every overlap finding produced by inspecting `subjects`
  (for scenario-level duplicates) and `requirements` (for requirement-level
  MUST-stem collisions).

  Identical inputs return equal findings lists — the analyzer does not
  consult external state.
  """
  @spec analyze([map()], [map()]) :: [finding()]
  def analyze(subjects, requirements) when is_list(subjects) and is_list(requirements) do
    (detect_duplicate_covers(subjects) ++ detect_must_stem_collision(requirements))
    |> sort_findings()
  end

  ## ── Detectors ─────────────────────────────────────────────────────

  defp detect_duplicate_covers(subjects) do
    Enum.flat_map(subjects, fn subject ->
      subject_id = subject_id(subject)
      scenarios = scenarios_of(subject)

      req_to_scenarios =
        Enum.reduce(scenarios, %{}, fn scenario, acc ->
          scenario_id = Map.get(scenario, "id") || Map.get(scenario, :id)
          covers = covers_of(scenario)

          Enum.reduce(covers, acc, fn req_id, inner ->
            Map.update(inner, req_id, [scenario_id], fn ids -> ids ++ [scenario_id] end)
          end)
        end)

      req_to_scenarios
      |> Enum.filter(fn {_req_id, ids} -> length(Enum.uniq(ids)) > 1 end)
      |> Enum.map(fn {req_id, ids} ->
        duplicate_covers_finding(subject_id, req_id, Enum.uniq(ids))
      end)
    end)
  end

  defp detect_must_stem_collision(requirements) do
    requirements
    |> Enum.filter(&must?/1)
    |> Enum.group_by(fn req -> {req_subject_id(req), canonical_stem(req)} end)
    |> Enum.flat_map(fn {{subject_id, _stem}, reqs} ->
      ids =
        reqs
        |> Enum.map(&req_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      case ids do
        [_, _ | _] -> [must_stem_collision_finding(subject_id, ids)]
        _ -> []
      end
    end)
  end

  ## ── Finding builders ──────────────────────────────────────────────

  defp duplicate_covers_finding(subject_id, req_id, scenario_ids) do
    sorted_ids = Enum.sort(scenario_ids)
    list = Enum.map_join(sorted_ids, ", ", &"`#{&1}`")

    %{
      code: "overlap/duplicate_covers",
      severity: :error,
      subject_id: subject_id,
      entity_id: req_id,
      message:
        finalize_message(
          "Requirement `#{req_id}` is covered redundantly by multiple scenarios in subject `#{subject_id || "<unknown>"}`: #{list}. Scenarios in the same subject must not list the same requirement id in their `covers:` field.",
          "fix: delete or re-scope the duplicate scenario(s), or split the requirement so each scenario covers a distinct id."
        )
    }
  end

  defp must_stem_collision_finding(subject_id, req_ids) do
    list = Enum.map_join(req_ids, ", ", &"`#{&1}`")

    %{
      code: "overlap/must_stem_collision",
      severity: :error,
      subject_id: subject_id,
      entity_id: List.first(req_ids),
      message:
        finalize_message(
          "Requirements #{list} in subject `#{subject_id || "<unknown>"}` share the same canonicalized MUST stem. Two `must`-priority requirements must not collapse to the same normative statement.",
          "fix: merge the requirements under a single id, or differentiate the statements so each captures a distinct obligation."
        )
    }
  end

  ## ── Helpers ───────────────────────────────────────────────────────

  defp subject_id(subject) do
    meta = indifferent_get(subject, "meta")
    id = indifferent_get(meta, "id") || indifferent_get(subject, "id")

    if is_binary(id) and id != "", do: id, else: nil
  end

  defp scenarios_of(subject) do
    case indifferent_get(subject, "scenarios") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp covers_of(scenario) do
    case indifferent_get(scenario, "covers") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp must?(req) do
    case indifferent_get(req, "priority") do
      "must" -> true
      :must -> true
      _ -> false
    end
  end

  defp req_subject_id(req) do
    case indifferent_get(req, "subject_id") do
      sid when is_binary(sid) -> sid
      _ -> nil
    end
  end

  defp req_id(req), do: indifferent_get(req, "id")

  # Reads a field on either a string-keyed map, an atom-keyed map, or a struct.
  # The index carries Zoi structs with atom keys (`%Meta{}`, `%Scenario{}`, ...);
  # `normalize_for_state/1` flattens those to string-keyed maps for state.json.
  # Overlap must accept either shape.
  defp indifferent_get(nil, _key), do: nil

  defp indifferent_get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        atom_key =
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end

        if atom_key, do: Map.get(map, atom_key), else: nil
    end
  end

  defp canonical_stem(req) do
    statement = Map.get(req, "statement") || Map.get(req, :statement) || ""

    normalized =
      statement
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[[:punct:]]+/u, " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    case Regex.run(~r/\b(must not|shall not|must|shall|should|may)\b(.*)/, normalized) do
      [_, modal, rest] -> String.trim(modal <> rest)
      _ -> normalized
    end
  end

  defp finalize_message(body, fix_line) do
    """
    #{String.trim_trailing(body)}

    ```
    #{fix_line}
    ```\
    """
  end

  defp sort_findings(findings) do
    Enum.sort_by(findings, fn f ->
      {
        f.subject_id || "",
        f.entity_id || "",
        f.code || ""
      }
    end)
  end
end
