defmodule SpecLedEx.BranchCheck do
  # covers: specled.branch_guard.subject_cochange specled.branch_guard.cross_cutting_decision specled.branch_guard.guidance_output specled.branch_guard.plan_docs_excluded specled.branch_guard.new_requirement_tag_warning specled.branch_guard.tag_findings_respect_enforcement
  @moduledoc false

  alias SpecLedEx.AppendOnly
  alias SpecLedEx.BranchCheck.Severity
  alias SpecLedEx.BranchCheck.Trailer
  alias SpecLedEx.ChangeAnalysis
  alias SpecLedEx.Config
  alias SpecLedEx.Overlap

  @per_code_defaults %{
    # branch_guard/* (existing)
    "branch_guard_unmapped_change" => :error,
    "branch_guard_missing_subject_update" => :error,
    "branch_guard_missing_decision_update" => :error,
    "branch_guard_requirement_without_test_tag" => :warning,
    # append_only/* (10 ratified codes)
    "append_only/requirement_deleted" => :error,
    "append_only/must_downgraded" => :error,
    "append_only/scenario_regression" => :error,
    "append_only/negative_removed" => :error,
    "append_only/disabled_without_reason" => :warning,
    "append_only/no_baseline" => :info,
    "append_only/adr_affects_widened" => :error,
    "append_only/same_pr_self_authorization" => :warning,
    "append_only/missing_change_type" => :warning,
    "append_only/decision_deleted" => :error,
    # overlap/* (2 ratified codes)
    "overlap/duplicate_covers" => :error,
    "overlap/must_stem_collision" => :error
  }

  def run(index, root, opts \\ []) do
    validate_base!(root, Keyword.get(opts, :base))

    analysis = ChangeAnalysis.analyze(index, root, opts)
    changed_subject_ids = MapSet.new(analysis.changed_subject_ids)
    severity_opts = severity_opts(root, analysis.base)

    file_findings =
      Enum.flat_map(analysis.policy_files, fn path ->
        impacted_subjects = Map.get(analysis.impacted_by_file, path, []) |> MapSet.new()

        cond do
          MapSet.size(impacted_subjects) == 0 and
              ChangeAnalysis.ignorable_deleted_policy_file?(root, path, changed_subject_ids) ->
            []

          MapSet.size(impacted_subjects) == 0 ->
            emit(
              severity_opts,
              "branch_guard_unmapped_change",
              "Changed file is not covered by any current-truth subject: #{path}",
              path
            )

          true ->
            missing_subject_ids =
              impacted_subjects
              |> MapSet.difference(changed_subject_ids)
              |> MapSet.to_list()
              |> Enum.sort()

            if missing_subject_ids == [] do
              []
            else
              emit(
                severity_opts,
                "branch_guard_missing_subject_update",
                "Changed file #{path} impacts subject specs that were not updated: #{Enum.join(missing_subject_ids, ", ")}",
                path
              )
            end
        end
      end)

    impacted_subjects = analysis.impacted_subject_ids |> MapSet.new()

    governance_findings =
      if needs_decision_update?(analysis.policy_files, impacted_subjects) and
           not analysis.decision_changed? do
        emit(
          severity_opts,
          "branch_guard_missing_decision_update",
          "Cross-cutting change spans multiple subjects but no decision file changed",
          nil
        )
      else
        []
      end

    tag_findings = new_requirement_tag_findings(index, analysis, root, severity_opts)

    {append_only_findings, overlap_findings} =
      contract_findings(index, root, analysis.base, severity_opts)

    findings =
      Enum.sort_by(
        file_findings ++
          governance_findings ++
          tag_findings ++
          append_only_findings ++
          overlap_findings,
        &{&1["code"], &1["file"] || "", &1["message"]}
      )

    %{
      "base" => analysis.base,
      "changed_files" => analysis.changed_files,
      "status" => if(findings == [], do: "pass", else: "fail"),
      "summary" => %{
        "changed_files" => length(analysis.changed_files),
        "policy_files" => length(analysis.policy_files),
        "findings" => length(findings)
      },
      "findings" => findings,
      "guidance" => guidance(analysis)
    }
  end

  @doc """
  Classifies the merged stdout/stderr output of a failed
  `git show <base>:.spec/state.json` into a `no_baseline` variant tag.

  Pure function — used by `fetch_prior_state/2` after the shell-out returns
  a non-zero exit, and unit-tested directly against canonical Git error
  strings.
  """
  @spec classify_load_error(binary()) :: :first_run | :shallow_clone | :bad_ref
  def classify_load_error(output) when is_binary(output) do
    cond do
      String.contains?(output, "does not exist in") -> :first_run
      String.contains?(output, "exists on disk, but not in") -> :first_run
      String.contains?(output, "bad object") -> :shallow_clone
      String.contains?(output, "bad revision") -> :shallow_clone
      String.contains?(output, "ambiguous argument") -> :bad_ref
      String.contains?(output, "unknown revision") -> :bad_ref
      true -> :first_run
    end
  end

  defp severity_opts(root, base) do
    config = Config.load(root)

    trailer_overrides =
      if is_binary(base) and base != "HEAD" do
        Trailer.read(root, base).overrides
      else
        %{}
      end

    [
      config_severities: config.branch_guard.severities,
      guardrails_severities: config.guardrails.severities,
      trailer_override: trailer_overrides
    ]
  end

  defp emit(severity_opts, code, message, file, subject_id \\ nil, default \\ nil) do
    resolved_default = default || Map.get(@per_code_defaults, code, :warning)

    case Severity.resolve(code, severity_opts, resolved_default) do
      :off ->
        []

      severity ->
        item =
          %{
            "severity" => Atom.to_string(severity),
            "code" => code,
            "message" => message,
            "file" => file
          }

        item = if subject_id, do: Map.put(item, "subject_id", subject_id), else: item
        [item]
    end
  end

  defp contract_findings(index, root, base, severity_opts) do
    current_state = SpecLedEx.normalize_for_state(index)
    decisions = Map.get(index, "decisions", []) |> List.wrap()

    # AppendOnly needs a real prior commit to compare against. When the base is
    # the trivial `HEAD` sentinel (no historical comparison) or the directory
    # is not a git repo, there is no meaningful prior state — skip entirely
    # rather than emit a no_baseline info on every run.
    append_only_raw =
      if append_only_applicable?(root, base) do
        case fetch_prior_state(root, base) do
          {:ok, prior_state} ->
            AppendOnly.analyze(prior_state, current_state, decisions)

          {:missing, variant} ->
            AppendOnly.analyze(:missing, current_state, decisions, baseline_variant: variant)
        end
      else
        []
      end

    subjects = Map.get(index, "subjects", []) |> List.wrap()
    requirements = get_in(current_state, ["index", "requirements"]) || []
    overlap_raw = Overlap.analyze(subjects, requirements)

    {render_findings(append_only_raw, severity_opts),
     render_findings(overlap_raw, severity_opts)}
  end

  defp append_only_applicable?(_root, nil), do: false
  defp append_only_applicable?(_root, "HEAD"), do: false

  defp append_only_applicable?(root, base) when is_binary(base) do
    git_repo?(root)
  end

  defp append_only_applicable?(_root, _base), do: false

  defp git_repo?(root) do
    {output, exit_code} =
      System.cmd("git", ["-C", root, "rev-parse", "--is-inside-work-tree"], into: "")

    exit_code == 0 and String.trim(output) == "true"
  end

  defp render_findings(findings, severity_opts) do
    Enum.flat_map(findings, fn finding ->
      default = Map.get(@per_code_defaults, finding.code, finding.severity)

      case Severity.resolve(finding.code, severity_opts, default) do
        :off ->
          []

        severity ->
          base_item = %{
            "severity" => Atom.to_string(severity),
            "code" => finding.code,
            "message" => finding.message,
            "file" => nil
          }

          [
            base_item
            |> maybe_put("subject_id", finding.subject_id)
            |> maybe_put("entity_id", finding.entity_id)
          ]
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp guidance(analysis) do
    change_type =
      cond do
        analysis.uncovered_policy_files != [] -> "outside_current_coverage"
        length(analysis.impacted_subject_ids) > 1 -> "cross_cutting"
        length(analysis.impacted_subject_ids) == 1 -> "single_subject"
        true -> "non_contract_or_meta"
      end

    %{
      "change_type" => change_type,
      "impacted_subject_ids" => analysis.impacted_subject_ids,
      "uncovered_policy_files" => analysis.uncovered_policy_files,
      "suggested_command" => "mix spec.next --base #{analysis.base}"
    }
  end

  defp needs_decision_update?(policy_files, impacted_subjects) do
    length(policy_files) > 1 and MapSet.size(impacted_subjects) > 1
  end

  defp new_requirement_tag_findings(index, analysis, root, severity_opts) do
    case Map.get(index, "test_tags") do
      nil ->
        []

      tag_map when is_map(tag_map) ->
        test_tags_default = test_tags_default(Map.get(index, "test_tags_config"))
        subjects_by_file = subjects_by_file(index)

        analysis.changed_files
        |> Enum.filter(&spec_file?/1)
        |> Enum.flat_map(fn path ->
          subject = Map.get(subjects_by_file, path)

          if subject do
            subject_id = subject_id(subject)
            tagged_tests_covers = tagged_tests_cover_ids(subject)
            current_ids = must_ids_from_subject(subject)
            base_ids = base_must_ids(root, analysis.base, path)
            new_ids = current_ids -- base_ids

            new_ids
            |> Enum.filter(&MapSet.member?(tagged_tests_covers, &1))
            |> Enum.reject(&Map.has_key?(tag_map, &1))
            |> Enum.flat_map(fn id ->
              emit(
                severity_opts,
                "branch_guard_requirement_without_test_tag",
                "New must requirement has no backing @tag spec annotation: #{id}",
                path,
                subject_id,
                test_tags_default
              )
            end)
          else
            []
          end
        end)
    end
  end

  defp tagged_tests_cover_ids(subject) do
    subject
    |> Map.get("verification", Map.get(subject, :verification, []))
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn v ->
      kind = Map.get(v, "kind", Map.get(v, :kind))
      kind == "tagged_tests"
    end)
    |> Enum.flat_map(fn v ->
      v |> Map.get("covers", Map.get(v, :covers, [])) |> List.wrap()
    end)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp test_tags_default(%{"enforcement" => "error"}), do: :error
  defp test_tags_default(_), do: nil

  defp subjects_by_file(index) do
    index
    |> Map.get("subjects")
    |> List.wrap()
    |> Enum.reduce(%{}, fn subject, acc ->
      case Map.get(subject, "file") do
        file when is_binary(file) -> Map.put(acc, file, subject)
        _ -> acc
      end
    end)
  end

  defp subject_id(subject) do
    case subject do
      %{"meta" => %{"id" => id}} when is_binary(id) and id != "" -> id
      _ -> Map.get(subject, "file")
    end
  end

  defp must_ids_from_subject(subject) do
    subject
    |> Map.get("requirements")
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.filter(fn req -> field(req, "priority") == "must" end)
    |> Enum.map(&field(&1, "id"))
    |> Enum.reject(&is_nil/1)
  end

  defp field(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key, Map.get(map, String.to_atom(key)))
  end

  defp field(_, _), do: nil

  defp base_must_ids(root, base, path) do
    case git_show(root, base, path) do
      {:ok, content} -> extract_must_ids(content)
      :missing -> []
    end
  end

  defp git_show(root, base, path) when is_binary(base) do
    {output, exit_code} =
      System.cmd("git", ["-C", root, "show", "#{base}:#{path}"], stderr_to_stdout: true)

    if exit_code == 0, do: {:ok, output}, else: :missing
  end

  defp git_show(_root, _base, _path), do: :missing

  defp extract_must_ids(content) do
    ~r/```([^\n`]*)\n(.*?)\n```/ms
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn [info_string, block] ->
      if info_string_has_requirements_tag?(info_string) do
        case YamlElixir.read_from_string(block) do
          {:ok, items} when is_list(items) ->
            items
            |> Enum.filter(&is_map/1)
            |> Enum.filter(fn item -> Map.get(item, "priority") == "must" end)
            |> Enum.map(&Map.get(&1, "id"))
            |> Enum.reject(&is_nil/1)

          _ ->
            []
        end
      else
        []
      end
    end)
  end

  defp info_string_has_requirements_tag?(info_string) do
    info_string
    |> String.split(~r/\s+/, trim: true)
    |> Enum.any?(&(&1 == "spec-requirements"))
  end

  defp spec_file?(path),
    do: String.starts_with?(path, ".spec/specs/") and String.ends_with?(path, ".spec.md")

  ## ── Prior-state loader split (fetch_prior_state + classify_load_error) ──

  defp fetch_prior_state(_root, nil), do: {:missing, :first_run}

  defp fetch_prior_state(root, base) when is_binary(base) do
    case git_show_state_json(root, base) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, state} when is_map(state) -> {:ok, state}
          _ -> {:missing, :first_run}
        end

      {:error, output} ->
        variant =
          cond do
            shallow_clone?(root) -> :shallow_clone
            true -> classify_load_error(output)
          end

        {:missing, variant}
    end
  end

  defp git_show_state_json(root, base) do
    {output, exit_code} =
      System.cmd(
        "git",
        ["-C", root, "show", "#{base}:.spec/state.json"],
        stderr_to_stdout: true
      )

    if exit_code == 0, do: {:ok, output}, else: {:error, output}
  end

  defp shallow_clone?(root) do
    {output, exit_code} =
      System.cmd("git", ["-C", root, "rev-parse", "--is-shallow-repository"], into: "")

    exit_code == 0 and String.trim(output) == "true"
  end

  ## ── --base validation (commit-only refs, C13) ──────────────────────

  defp validate_base!(_root, nil), do: :ok
  defp validate_base!(_root, "HEAD"), do: :ok

  defp validate_base!(root, base) when is_binary(base) do
    {_output, exit_code} =
      System.cmd(
        "git",
        ["-C", root, "rev-parse", "--verify", "#{base}^{commit}"],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      raise ArgumentError,
            "--base #{inspect(base)} does not resolve to a commit (git rev-parse --verify '#{base}^{commit}' failed)"
    end

    :ok
  end
end
