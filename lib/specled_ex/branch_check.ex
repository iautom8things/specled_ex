defmodule SpecLedEx.BranchCheck do
  # covers: specled.branch_guard.subject_cochange specled.branch_guard.cross_cutting_decision specled.branch_guard.guidance_output specled.branch_guard.plan_docs_excluded specled.branch_guard.new_requirement_tag_warning specled.branch_guard.tag_findings_respect_enforcement specled.branch_guard.realization_tiers_from_config specled.branch_guard.realization_unknown_tier_finding specled.branch_guard.file_touch_yields_to_attested_file specled.branch_guard.file_touch_per_subject_independence specled.branch_guard.file_touch_severity_config_wins specled.branch_guard.file_touch_tagged_tests_attested specled.branch_guard.file_touch_detector_failure_strict
  @moduledoc false

  alias SpecLedEx.AppendOnly
  alias SpecLedEx.BaseView
  alias SpecLedEx.BranchCheck.Severity
  alias SpecLedEx.BranchCheck.Trailer
  alias SpecLedEx.ChangeAnalysis
  alias SpecLedEx.Config
  alias SpecLedEx.Overlap
  alias SpecLedEx.Realization.Orchestrator

  @per_code_defaults %{
    # branch_guard/* (existing)
    "branch_guard_unmapped_change" => :error,
    "branch_guard_missing_subject_update" => :error,
    "branch_guard_missing_decision_update" => :error,
    "branch_guard_requirement_without_test_tag" => :warning,
    # realization tier findings (q59.9 wiring)
    "branch_guard_realization_drift" => :warning,
    "branch_guard_dangling_binding" => :error,
    "branch_guard_realization_unknown_tier" => :warning,
    "detector_unavailable" => :info,
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

    config = Config.load(root)
    analysis = ChangeAnalysis.analyze(index, root, opts)
    changed_subject_ids = MapSet.new(analysis.changed_subject_ids)
    severity_opts = severity_opts(config, root, analysis.base)

    # Hoist the realization run so its attestation map is available to the
    # file-touch loop below. The same raw findings flow through
    # `realization_findings/2` (severity resolution + emit) so we don't run
    # the orchestrator twice.
    {realization_raw, attestations} = run_realization(index, root, opts, config)

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

            missing_subject_update_findings(
              missing_subject_ids,
              path,
              attestations,
              severity_opts
            )
        end
      end)

    impacted_subjects = analysis.impacted_subject_ids |> MapSet.new()

    governance_findings =
      if needs_decision_update?(analysis.policy_files, impacted_subjects) and
           not analysis.decision_changed? do
        emit(
          severity_opts,
          "branch_guard_missing_decision_update",
          finalize_message(
            "Cross-cutting change spans multiple subjects but no decision file changed. Durable cross-cutting policy (it constrains future changes, spans subjects beyond this branch, or records a rejected alternative) needs an ADR; a change that is not durable policy does not.",
            "fix: if this branch changes durable cross-cutting policy, add or revise an ADR (`mix spec.decision.new <id> --title \"...\"`); if it does not, record `Spec-Drift: branch_guard_missing_decision_update=info` as a git trailer on a commit in this range, with a one-line reason in the commit body."
          ),
          nil
        )
      else
        []
      end

    tag_findings = new_requirement_tag_findings(index, analysis, root, severity_opts)

    {append_only_findings, overlap_findings} =
      contract_findings(index, root, analysis.base, severity_opts)

    realization_findings =
      realization_unknown_tier_findings(config, severity_opts) ++
        realization_findings(realization_raw, severity_opts, accept_drift?(opts))

    findings =
      Enum.sort_by(
        file_findings ++
          governance_findings ++
          tag_findings ++
          append_only_findings ++
          overlap_findings ++
          realization_findings,
        &{&1["code"], &1["file"] || "", &1["message"]}
      )

    errors = Enum.count(findings, &(&1["severity"] == "error"))

    %{
      "base" => analysis.base,
      "changed_files" => analysis.changed_files,
      "status" => if(errors > 0, do: "fail", else: "pass"),
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
      String.contains?(output, "not a tree object") -> :bad_ref
      true -> :first_run
    end
  end

  defp severity_opts(config, root, base) do
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

  # Same message shape as AppendOnly/Overlap findings: prose body followed
  # by a code-fenced `fix:` block naming the sanctioned resolutions.
  defp finalize_message(body, fix_line) do
    """
    #{String.trim_trailing(body)}

    ```
    #{fix_line}
    ```\
    """
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

  # Run the realization orchestrator once for this branch check, returning
  # `{raw_findings, attestations}`. The raw findings flow into
  # `realization_findings/2` for severity resolution; the attestation map
  # drives the file-touch attested/unattested partition (see
  # `missing_subject_update_findings/4`).
  defp run_realization(index, root, opts, config) do
    realization_opts = [
      root: root,
      umbrella?: Keyword.get(opts, :umbrella?, false),
      context: Keyword.get(opts, :context),
      commit_hashes?: Keyword.get(opts, :commit_realization_hashes?, true),
      accept_drift?: accept_drift?(opts)
    ]

    realization_opts =
      case config.realization.enabled_tiers do
        nil ->
          realization_opts

        enabled_tiers when is_list(enabled_tiers) ->
          Keyword.put(realization_opts, :enabled_tiers, enabled_tiers)
      end

    Orchestrator.run_with_attestations(index, realization_opts)
  end

  defp realization_unknown_tier_findings(config, severity_opts) do
    config.realization.rejected
    |> List.wrap()
    |> Enum.flat_map(fn token ->
      emit(
        severity_opts,
        "branch_guard_realization_unknown_tier",
        "realization.enabled_tiers contains unknown tier #{render_rejected_tier(token)}; valid tiers: api_boundary, implementation, expanded_behavior, typespecs, use — this tier will not run.",
        ".spec/config.yml"
      )
    end)
  end

  defp render_rejected_tier(token) when is_binary(token), do: token
  defp render_rejected_tier(token), do: inspect(token)

  # covers: specled.realized_by.drift_acceptance
  #
  # `--accept-drift` downgrades a `branch_guard_realization_drift` finding to
  # `:info` (at trailer precedence, so it beats a `branch_guard.severities`
  # `:error` pin; a config `:off` still absorbs) — but ONLY for the bindings the
  # post-run refresh actually rebaselines. That healed set is exactly
  # `Orchestrator.flat_tiers/0`, so silencing is scoped to the same tiers:
  # silence exactly what you heal. Two exclusions fall out of that principle:
  #
  #   * implementation-tier drift is a SIGNAL, not a gate — its hashes are never
  #     rebaselined (the refresh is flat-tier only), so it is never silenced and
  #     stays at its configured severity.
  #   * a dangling binding is a genuine error that blocks the refresh entirely
  #     (see the `Orchestrator` refresh gate), so when any dangling is present
  #     nothing is healed and therefore nothing is silenced this run.
  defp realization_findings(raw, severity_opts, accept_drift?) do
    healable? = accept_drift? and not Enum.any?(raw, &dangling_finding?/1)

    Enum.flat_map(raw, fn finding ->
      code = Map.get(finding, "code")
      default = Map.get(@per_code_defaults, code, :warning)
      opts = drift_severity_opts(finding, code, severity_opts, healable?)

      case Severity.resolve(code, opts, default) do
        :off ->
          []

        severity ->
          [Map.put(finding, "severity", Atom.to_string(severity))]
      end
    end)
  end

  # Scope the accept-drift `:info` override to the tiers the refresh heals.
  # Only a `branch_guard_realization_drift` finding in a flat (refreshed) tier is
  # downgraded, and only on a healable run (accept + no dangling error).
  defp drift_severity_opts(finding, "branch_guard_realization_drift", severity_opts, true) do
    if Map.get(finding, "tier") in flat_tier_names() do
      Keyword.update(
        severity_opts,
        :trailer_override,
        %{"branch_guard_realization_drift" => :info},
        &Map.put(&1, "branch_guard_realization_drift", :info)
      )
    else
      severity_opts
    end
  end

  defp drift_severity_opts(_finding, _code, severity_opts, _healable?), do: severity_opts

  defp flat_tier_names,
    do: Enum.map(SpecLedEx.Realization.Orchestrator.flat_tiers(), &Atom.to_string/1)

  defp dangling_finding?(finding),
    do: Map.get(finding, "code") == "branch_guard_dangling_binding"

  defp accept_drift?(opts), do: Keyword.get(opts, :accept_drift?, false) == true

  # covers: specled.branch_guard.file_touch_yields_to_attested_file
  # covers: specled.branch_guard.file_touch_per_subject_independence
  # covers: specled.branch_guard.file_touch_severity_config_wins
  # covers: specled.branch_guard.file_touch_tagged_tests_attested
  # covers: specled.branch_guard.file_touch_detector_failure_strict
  #
  # Partition the missing-subject ids for a given changed `path` into the
  # attested-clean and unattested halves, then emit one
  # `branch_guard_missing_subject_update` finding per non-empty half:
  #
  #   * Attested half: default severity `:info`, distinctive message naming
  #     the attesting binding(s) extracted from the attestation value tuple.
  #   * Unattested half: default severity `:error`, original message.
  #
  # The finding code remains `branch_guard_missing_subject_update` in both
  # halves; the downgrade flows through `Severity.resolve/3` as the `default`
  # argument so user severity overrides (config or trailer) still win, and
  # `:off` absorbs both.
  #
  # The three-condition attestation predicate (binding's source path returned
  # + path equals the changed file + MFA not in this run's drift/dangling
  # finding set) is enforced upstream in
  # `Orchestrator.run_with_attestations/2`. Here we only consult the resulting
  # map: presence of `path` under `subject_id` in `attestations` means all
  # three held for at least one binding of that subject. Detector failures
  # (path == nil, or a tier-wide `detector_unavailable` that prevented binding
  # collection) leave the entry absent and fall through to the strict
  # `:error` branch.
  defp missing_subject_update_findings([], _path, _attestations, _severity_opts), do: []

  defp missing_subject_update_findings(missing_subject_ids, path, attestations, severity_opts) do
    {attested, unattested} =
      Enum.split_with(missing_subject_ids, fn sid ->
        attestations
        |> Map.get(sid, %{})
        |> Map.has_key?(path)
      end)

    attested_findings =
      Enum.flat_map(attested, fn sid ->
        bindings = attesting_bindings(attestations, sid, path)
        message = attested_missing_subject_update_message(path, sid, bindings)

        emit(
          severity_opts,
          "branch_guard_missing_subject_update",
          message,
          path,
          nil,
          :info
        )
      end)

    unattested_findings =
      if unattested == [] do
        []
      else
        emit(
          severity_opts,
          "branch_guard_missing_subject_update",
          "Changed file #{path} impacts subject specs that were not updated: #{Enum.join(unattested, ", ")}",
          path,
          nil,
          :error
        )
      end

    attested_findings ++ unattested_findings
  end

  defp attesting_bindings(attestations, subject_id, path) do
    case attestations |> Map.get(subject_id, %{}) |> Map.get(path) do
      {:attested_clean, mfas} when is_list(mfas) -> mfas
      _ -> []
    end
  end

  defp attested_missing_subject_update_message(path, subject_id, bindings) do
    "Changed file #{path} impacts subject #{subject_id}; spec.md not co-changed, " <>
      "but realization attested binding(s) #{Enum.join(bindings, ", ")} as clean — informational only."
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
          {:ok, %{"state" => prior_state}} ->
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

    {render_findings(append_only_raw, severity_opts), render_findings(overlap_raw, severity_opts)}
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
    BaseView.build(root, base)
  end

  def shallow_clone?(root) do
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
