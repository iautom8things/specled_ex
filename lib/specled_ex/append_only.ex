defmodule SpecLedEx.AppendOnly do
  # covers: specled.append_only.requirement_deleted specled.append_only.must_downgraded specled.append_only.scenario_regression specled.append_only.negative_removed specled.append_only.disabled_without_reason specled.append_only.no_baseline specled.append_only.adr_affects_widened specled.append_only.same_pr_self_authorization specled.append_only.missing_change_type specled.append_only.decision_deleted specled.append_only.identity specled.append_only.findings_sorted specled.append_only.fix_block_discipline
  @moduledoc """
  Pure diff-time append-only detectors for `.spec/` content.

  `analyze/4` is a total function over `(prior_state, current_state, decisions, opts)`:

    * `prior_state` — the state payload reconstructed from
      `git show <base>:.spec/state.json` via `SpecLedEx.normalize_for_state/1`,
      or the atom `:missing` for first-run / shallow-clone / bad-ref
      bootstrap cases.
    * `current_state` — the head-side state payload (same shape).
    * `decisions` — the head-side list of parsed decisions, each carrying a
      `"meta"` map with the frontmatter fields
      (`change_type`, `affects`, `status`, `reverses_what`, `replaces`).
      This is the shape produced by `SpecLedEx.DecisionParser.parse_file/2`.
    * `opts` — keyword options. `:baseline_variant` (`:first_run`,
      `:shallow_clone`, or `:bad_ref`) tags the `no_baseline` finding.

  The module has no Git I/O. It does not cache modal classes on
  requirements or in `state.json` (per
  `specled.decision.modal_class_diff_time`) — `SpecLedEx.ModalClass.classify/1`
  runs afresh for every requirement that has a statement under comparison.

  Each finding's `:message` ends in a code-fenced `fix:` block so the
  remediation instruction is carried alongside the diagnostic.
  """

  alias SpecLedEx.ModalClass

  @weakening_set ~w(deprecates weakens narrows-scope adds-exception)

  @type severity :: :error | :warning | :info

  @type finding :: %{
          code: String.t(),
          severity: severity(),
          subject_id: String.t() | nil,
          entity_id: String.t() | nil,
          message: String.t()
        }

  @doc """
  Returns every append-only finding produced by diffing `prior_state` against
  `current_state` in the presence of the head-side `decisions` list.

  Returns `[]` when called with identical prior and current states and an
  empty decisions list (identity property).

  Returns exactly one `append_only/no_baseline` finding when `prior_state`
  is `:missing`, tagged by `opts[:baseline_variant]` (default `:first_run`).
  """
  @spec analyze(map() | :missing, map(), [map()], keyword()) :: [finding()]
  def analyze(prior_state, current_state, decisions, opts \\ [])

  def analyze(:missing, _current_state, _decisions, opts) do
    variant = Keyword.get(opts, :baseline_variant, :first_run)
    [no_baseline_finding(variant)]
  end

  def analyze(prior, current, decisions, _opts)
      when is_map(prior) and is_map(current) and is_list(decisions) do
    prior_reqs = requirements_by_id(prior)
    current_reqs = requirements_by_id(current)

    prior_decision_ids = decision_ids(prior)
    new_head_adrs = new_in_diff(decisions, prior_decision_ids)

    removed_ids = MapSet.difference(key_set(prior_reqs), key_set(current_reqs))

    self_auth_adrs = self_authorizing_adrs(new_head_adrs, removed_ids)
    self_auth_covered_ids = self_auth_covered_ids(self_auth_adrs)

    {deletion_findings, deletion_consulted_ids} =
      detect_requirement_deleted(
        prior_reqs,
        current_reqs,
        decisions,
        self_auth_covered_ids
      )

    {downgrade_findings, downgrade_consulted_ids} =
      detect_must_downgraded(prior_reqs, current_reqs, decisions)

    {regression_findings, regression_consulted_ids} =
      detect_scenario_regression(prior, current, decisions)

    {polarity_findings, polarity_consulted_ids} =
      detect_negative_removed(prior_reqs, current_reqs, decisions)

    consulted_ids =
      deletion_consulted_ids
      |> MapSet.union(downgrade_consulted_ids)
      |> MapSet.union(regression_consulted_ids)
      |> MapSet.union(polarity_consulted_ids)

    (deletion_findings ++
       downgrade_findings ++
       regression_findings ++
       polarity_findings ++
       detect_same_pr_self_authorization(self_auth_adrs, decisions) ++
       detect_missing_change_type(decisions, consulted_ids) ++
       detect_disabled_without_reason(current) ++
       detect_adr_affects_widened(prior, current) ++
       detect_decision_deleted(prior, current))
    |> sort_findings()
  end

  @doc false
  def weakening_set, do: @weakening_set

  ## ── Detectors ─────────────────────────────────────────────────────

  defp detect_requirement_deleted(prior_reqs, current_reqs, decisions, self_auth_covered_ids) do
    Enum.reduce(prior_reqs, {[], MapSet.new()}, fn {id, prior}, {findings, consulted} ->
      cond do
        Map.has_key?(current_reqs, id) ->
          {findings, consulted}

        MapSet.member?(self_auth_covered_ids, id) ->
          # Same-PR self-authorization warning takes over; suppress deletion error.
          {findings, consulted}

        true ->
          case authorizing_decision(decisions, id) do
            {:authorized, _adr} ->
              {findings, MapSet.put(consulted, id)}

            {:missing_change_type, _adr} ->
              {[requirement_deleted_finding(id, prior) | findings], MapSet.put(consulted, id)}

            :none ->
              {[requirement_deleted_finding(id, prior) | findings], MapSet.put(consulted, id)}
          end
      end
    end)
  end

  defp detect_must_downgraded(prior_reqs, current_reqs, decisions) do
    Enum.reduce(prior_reqs, {[], MapSet.new()}, fn {id, prior}, {findings, consulted} ->
      case Map.fetch(current_reqs, id) do
        {:ok, current} ->
          prior_modal = ModalClass.classify(statement(prior))
          current_modal = ModalClass.classify(statement(current))

          if ModalClass.downgrade?(prior_modal, current_modal) do
            case authorizing_decision(decisions, id) do
              {:authorized, _adr} ->
                {findings, MapSet.put(consulted, id)}

              _ ->
                finding =
                  must_downgraded_finding(id, prior, current, prior_modal, current_modal)

                {[finding | findings], MapSet.put(consulted, id)}
            end
          else
            {findings, consulted}
          end

        :error ->
          # Handled by detect_requirement_deleted.
          {findings, consulted}
      end
    end)
  end

  defp detect_scenario_regression(prior, current, decisions) do
    prior_counts = scenario_counts_by_requirement(prior)
    current_counts = scenario_counts_by_requirement(current)
    prior_reqs = requirements_by_id(prior)
    current_reqs = requirements_by_id(current)

    prior_counts
    |> Enum.reduce({[], MapSet.new()}, fn {req_id, prior_count}, {findings, consulted} ->
      current_count = Map.get(current_counts, req_id, 0)

      cond do
        current_count >= prior_count ->
          {findings, consulted}

        # If the requirement itself was removed, requirement_deleted or
        # same_pr_self_authorization already covers the regression.
        not Map.has_key?(current_reqs, req_id) ->
          {findings, consulted}

        true ->
          case authorizing_decision(decisions, req_id) do
            {:authorized, _adr} ->
              {findings, MapSet.put(consulted, req_id)}

            _ ->
              prior_req = Map.get(prior_reqs, req_id)

              finding =
                scenario_regression_finding(
                  req_id,
                  prior_req,
                  prior_count,
                  current_count
                )

              {[finding | findings], MapSet.put(consulted, req_id)}
          end
      end
    end)
  end

  defp detect_negative_removed(prior_reqs, current_reqs, decisions) do
    Enum.reduce(prior_reqs, {[], MapSet.new()}, fn {id, prior}, {findings, consulted} ->
      if effective_polarity(prior) == :negative do
        case Map.fetch(current_reqs, id) do
          {:ok, current} ->
            if effective_polarity(current) == :negative do
              {findings, consulted}
            else
              case authorizing_decision(decisions, id) do
                {:authorized, _adr} ->
                  {findings, MapSet.put(consulted, id)}

                _ ->
                  {[negative_removed_finding(id, prior, current) | findings],
                   MapSet.put(consulted, id)}
              end
            end

          :error ->
            {findings, consulted}
        end
      else
        {findings, consulted}
      end
    end)
  end

  defp detect_disabled_without_reason(state) do
    state
    |> scenarios()
    |> Enum.flat_map(fn scenario ->
      execute = Map.get(scenario, "execute")
      reason = scenario |> Map.get("reason", "") |> to_string() |> String.trim()

      if execute == false and reason == "" do
        [disabled_without_reason_finding(scenario)]
      else
        []
      end
    end)
  end

  defp detect_adr_affects_widened(prior, current) do
    prior_by_id = decisions_by_id(prior)
    current_by_id = decisions_by_id(current)

    prior_by_id
    |> Enum.flat_map(fn {id, prior_adr} ->
      if Map.get(prior_adr, "status") == "accepted" do
        case Map.fetch(current_by_id, id) do
          {:ok, current_adr} ->
            maybe_adr_drift_finding(id, prior_adr, current_adr)

          :error ->
            # Absent in current → decision_deleted handles it.
            []
        end
      else
        []
      end
    end)
  end

  defp detect_same_pr_self_authorization(self_auth_adrs, _decisions) do
    Enum.map(self_auth_adrs, &same_pr_self_authorization_finding/1)
  end

  defp detect_missing_change_type(decisions, consulted_ids) do
    decisions
    |> Enum.flat_map(fn decision ->
      meta = meta(decision)
      id = meta_get(meta, "id")
      change_type = meta_get(meta, "change_type")
      affects = meta_get(meta, "affects") || []

      consulted? = Enum.any?(affects, &MapSet.member?(consulted_ids, &1))

      if consulted? and (is_nil(change_type) or change_type == "") do
        [missing_change_type_finding(id, decision)]
      else
        []
      end
    end)
  end

  defp detect_decision_deleted(prior, current) do
    prior_by_id = decisions_by_id(prior)
    current_by_id = decisions_by_id(current)

    prior_by_id
    |> Enum.flat_map(fn {id, prior_adr} ->
      if Map.has_key?(current_by_id, id) do
        []
      else
        [decision_deleted_finding(id, prior_adr)]
      end
    end)
  end

  ## ── Finding builders ──────────────────────────────────────────────

  defp no_baseline_finding(variant) do
    variant_note =
      case variant do
        :first_run -> "first-run bootstrap (no prior state.json)"
        :shallow_clone -> "shallow-clone (base ref unreachable in the fetched history)"
        :bad_ref -> "bad base ref (resolved but carries no .spec/state.json)"
        other -> "bootstrap (#{inspect(other)})"
      end

    %{
      code: "append_only/no_baseline",
      severity: :info,
      subject_id: nil,
      entity_id: nil,
      message:
        finalize_message(
          "No prior state.json baseline is available for comparison: #{variant_note}.",
          "fix: commit .spec/state.json on the base branch, or deepen the clone so <base> resolves."
        )
    }
  end

  defp requirement_deleted_finding(id, prior_req) do
    subject_id = Map.get(prior_req, "subject_id")

    %{
      code: "append_only/requirement_deleted",
      severity: :error,
      subject_id: subject_id,
      entity_id: id,
      message:
        finalize_message(
          "Requirement `#{id}` was present at base and is absent at head. Deletion is only authorized when a head-side ADR in the weakening set names `#{id}` in its `affects:` list.",
          "fix: author an ADR with change_type in {deprecates, weakens, narrows-scope, adds-exception} and affects: [#{id}] — or restore the requirement in its spec file."
        )
    }
  end

  defp must_downgraded_finding(id, prior_req, _current_req, prior_modal, current_modal) do
    subject_id = Map.get(prior_req, "subject_id")

    %{
      code: "append_only/must_downgraded",
      severity: :error,
      subject_id: subject_id,
      entity_id: id,
      message:
        finalize_message(
          "Requirement `#{id}` was `#{format_modal(prior_modal)}` at base and classifies to `#{format_modal(current_modal)}` at head — normative force was reduced without an authorizing ADR.",
          "fix: author an ADR with change_type in {weakens, narrows-scope, adds-exception} and affects: [#{id}], or restore the prior modal strength in the statement."
        )
    }
  end

  defp scenario_regression_finding(id, prior_req, prior_count, current_count) do
    subject_id = if prior_req, do: Map.get(prior_req, "subject_id"), else: nil

    %{
      code: "append_only/scenario_regression",
      severity: :error,
      subject_id: subject_id,
      entity_id: id,
      message:
        finalize_message(
          "Scenarios covering `#{id}` dropped from #{prior_count} at base to #{current_count} at head without an authorizing ADR.",
          "fix: restore the missing scenario(s), or author an ADR with change_type in {weakens, narrows-scope, adds-exception} and affects: [#{id}]."
        )
    }
  end

  defp negative_removed_finding(id, prior_req, _current_req) do
    subject_id = Map.get(prior_req, "subject_id")

    %{
      code: "append_only/negative_removed",
      severity: :error,
      subject_id: subject_id,
      entity_id: id,
      message:
        finalize_message(
          "Requirement `#{id}` carried `polarity: negative` at base (explicit or auto-inferred from MUST NOT / SHALL NOT) and no longer does at head.",
          "fix: restore the negative assertion, or author an ADR with change_type in {weakens, narrows-scope, adds-exception} and affects: [#{id}]."
        )
    }
  end

  defp disabled_without_reason_finding(scenario) do
    id = Map.get(scenario, "id")
    subject_id = Map.get(scenario, "subject_id")

    %{
      code: "append_only/disabled_without_reason",
      severity: :warning,
      subject_id: subject_id,
      entity_id: id,
      message:
        finalize_message(
          "Scenario `#{id}` has `execute: false` but no `reason:` field — future readers have no record of why this scenario was stubbed out.",
          "fix: add a non-empty `reason:` field to the scenario block, or flip `execute:` back to `true` and add the coverage."
        )
    }
  end

  defp maybe_adr_drift_finding(id, prior_adr, current_adr) do
    drifts =
      []
      |> drift_on("affects", prior_adr, current_adr)
      |> drift_on("change_type", prior_adr, current_adr)
      |> drift_on("reverses_what", prior_adr, current_adr)

    case drifts do
      [] ->
        []

      _ ->
        [
          %{
            code: "append_only/adr_affects_widened",
            severity: :error,
            subject_id: nil,
            entity_id: id,
            message:
              finalize_message(
                "ADR `#{id}` was `status: accepted` at base but its structural fields changed at head (#{Enum.join(drifts, "; ")}). Accepted ADRs are immutable per specled.decision.adr_append_only.",
                "fix: revert the field edit on the accepted ADR, or author a new ADR (change_type: supersedes with replaces: [#{id}]) that captures the new decision."
              )
          }
        ]
    end
  end

  defp drift_on(acc, field, prior_adr, current_adr) do
    head = Map.get(current_adr, field)
    base = Map.get(prior_adr, field)

    if head == base do
      acc
    else
      acc ++ ["#{field}: #{inspect(base)} → #{inspect(head)}"]
    end
  end

  defp same_pr_self_authorization_finding(%{id: id, affects: affects}) do
    %{
      code: "append_only/same_pr_self_authorization",
      severity: :warning,
      subject_id: nil,
      entity_id: id,
      message:
        finalize_message(
          "ADR `#{id}` is new in this diff and its `affects:` list (#{inspect(affects)}) exactly matches the set of requirement ids removed in this same diff — the ADR is self-authorizing its own deletion. Visible but not blocked; review decides.",
          "fix: land the removal in a separate PR from the authorizing ADR, or confirm in review that the self-authorization is intentional."
        )
    }
  end

  defp missing_change_type_finding(id, _decision) do
    display_id = id || "<unknown>"

    %{
      code: "append_only/missing_change_type",
      severity: :warning,
      subject_id: nil,
      entity_id: id,
      message:
        finalize_message(
          "ADR `#{display_id}` was consulted during an authorization lookup but carries no `change_type:` field (v1 treats this as a warning per specled.decision.change_type_enum_v1).",
          "fix: add `change_type:` to the ADR frontmatter — one of deprecates, weakens, narrows-scope, adds-exception, supersedes, clarifies, refines."
        )
    }
  end

  defp decision_deleted_finding(id, _prior_adr) do
    %{
      code: "append_only/decision_deleted",
      severity: :error,
      subject_id: nil,
      entity_id: id,
      message:
        finalize_message(
          "Decision `#{id}` was present at base and is absent at head. ADR files cannot be deleted — the only authorized removal is a status transition to `deprecated` or `superseded` on the existing file.",
          "fix: restore the ADR file and update its `status:` to `deprecated` or `superseded` instead of deleting it."
        )
    }
  end

  ## ── Helpers ───────────────────────────────────────────────────────

  defp finalize_message(body, fix_line) do
    """
    #{String.trim_trailing(body)}

    ```
    #{fix_line}
    ```\
    """
  end

  defp format_modal(:must), do: "MUST"
  defp format_modal(:shall), do: "SHALL"
  defp format_modal(:must_not), do: "MUST NOT"
  defp format_modal(:shall_not), do: "SHALL NOT"
  defp format_modal(:should), do: "SHOULD"
  defp format_modal(:may), do: "MAY"
  defp format_modal(:none), do: "NONE"

  defp requirements_by_id(state) do
    state
    |> get_in_list(["index", "requirements"])
    |> Enum.reduce(%{}, fn req, acc ->
      case Map.get(req, "id") do
        nil -> acc
        id -> Map.put(acc, id, req)
      end
    end)
  end

  defp scenarios(state) do
    get_in_list(state, ["index", "scenarios"])
  end

  defp scenario_counts_by_requirement(state) do
    state
    |> scenarios()
    |> Enum.reduce(%{}, fn scenario, acc ->
      scenario
      |> Map.get("covers", [])
      |> Enum.reduce(acc, fn req_id, inner ->
        Map.update(inner, req_id, 1, &(&1 + 1))
      end)
    end)
  end

  defp decisions_by_id(state) do
    state
    |> get_in_list(["decisions", "items"])
    |> Enum.reduce(%{}, fn adr, acc ->
      case Map.get(adr, "id") do
        nil -> acc
        id -> Map.put(acc, id, adr)
      end
    end)
  end

  defp decision_ids(state) do
    state
    |> get_in_list(["decisions", "items"])
    |> Enum.reduce(MapSet.new(), fn adr, acc ->
      case Map.get(adr, "id") do
        nil -> acc
        id -> MapSet.put(acc, id)
      end
    end)
  end

  defp new_in_diff(decisions, prior_decision_ids) do
    decisions
    |> Enum.flat_map(fn decision ->
      meta = meta(decision)
      id = meta_get(meta, "id")

      cond do
        is_nil(id) -> []
        MapSet.member?(prior_decision_ids, id) -> []
        true -> [%{id: id, meta: meta}]
      end
    end)
  end

  defp self_authorizing_adrs(new_head_adrs, removed_ids) do
    new_head_adrs
    |> Enum.flat_map(fn %{id: id, meta: meta} ->
      change_type = meta_get(meta, "change_type")
      affects = meta_get(meta, "affects") || []

      cond do
        change_type not in @weakening_set ->
          []

        affects == [] ->
          []

        MapSet.equal?(MapSet.new(affects), removed_ids) ->
          [%{id: id, affects: affects, change_type: change_type}]

        true ->
          []
      end
    end)
  end

  defp self_auth_covered_ids(self_auth_adrs) do
    Enum.reduce(self_auth_adrs, MapSet.new(), fn %{affects: affects}, acc ->
      Enum.reduce(affects, acc, &MapSet.put(&2, &1))
    end)
  end

  defp authorizing_decision(decisions, id) do
    Enum.reduce_while(decisions, :none, fn decision, acc ->
      meta = meta(decision)
      change_type = meta_get(meta, "change_type")
      affects = meta_get(meta, "affects") || []

      if id in affects do
        cond do
          change_type in @weakening_set ->
            {:halt, {:authorized, decision}}

          is_nil(change_type) or change_type == "" ->
            # Surfaces as a missing_change_type warning, but does NOT authorize
            # the deletion — the requirement_deleted (or downgrade) fires too.
            {:cont, {:missing_change_type, decision}}

          true ->
            {:cont, acc}
        end
      else
        {:cont, acc}
      end
    end)
  end

  defp effective_polarity(req) do
    case Map.get(req, "polarity") do
      "negative" ->
        :negative

      "positive" ->
        :positive

      _ ->
        case ModalClass.classify(statement(req)) do
          :must_not -> :negative
          :shall_not -> :negative
          _ -> :positive
        end
    end
  end

  defp statement(req) do
    case Map.get(req, "statement") do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  defp meta(%{"meta" => m}) when is_map(m), do: m
  defp meta(decision) when is_map(decision), do: decision
  defp meta(_), do: %{}

  defp meta_get(meta, key) when is_map(meta), do: Map.get(meta, key)
  defp meta_get(_, _), do: nil

  defp get_in_list(state, path) do
    case get_in_path(state, path) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp get_in_path(value, []), do: value

  defp get_in_path(value, [key | rest]) when is_map(value) do
    get_in_path(Map.get(value, key), rest)
  end

  defp get_in_path(_, _), do: nil

  defp key_set(map) when is_map(map) do
    map |> Map.keys() |> MapSet.new()
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
