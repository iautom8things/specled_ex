defmodule SpecLedEx.Review do
  @moduledoc """
  Assembles the view-model rendered as the spec-aware PR review HTML.

  The renderer (`SpecLedEx.Review.Html`) is intentionally dumb — it expects
  the view-model returned by `build_view/3` and does no further data
  fetching. All git interaction, finding aggregation, and per-subject
  grouping happens here.
  """

  alias SpecLedEx.{ChangeAnalysis, Coverage, Verifier}
  alias SpecLedEx.Review.{CoverageClosure, FileDiff, SpecDiff}

  @doc """
  Builds the view-model for the current change set.

  Options:
    * `:base` — explicit base ref (defaults to ChangeAnalysis detection)
    * `:strict`, `:run_commands`, `:command_timeout_ms`, `:min_strength` —
      forwarded to `Verifier.verify/3`
  """
  def build_view(index, root, opts \\ []) do
    base_opt = Keyword.get(opts, :base)
    analysis = ChangeAnalysis.analyze(index, root, base: base_opt)
    verifier_opts = Keyword.drop(opts, [:base, :closure_reach_opts])
    verifier_report = Verifier.verify(index, root, verifier_opts)

    subjects_by_id = subjects_by_id(index)

    affected_subject_ids =
      MapSet.union(
        MapSet.new(analysis.changed_subject_ids),
        MapSet.new(analysis.impacted_subject_ids)
      )
      |> MapSet.to_list()
      |> Enum.sort()

    # covers: specled.spec_review.no_realized_by_degrades_spec_to_code
    # An affected subject with zero `realized_by` bindings produces a
    # synthetic `detector_unavailable` finding (reason `:no_realized_by`)
    # so the SPEC ↔ CODE leg renders as :degraded rather than silently ✓.
    # The same triangle-leg rendering pipeline (build_detector_unavailable_by_leg)
    # picks the synthetic findings up alongside tier-emitted ones.
    no_realized_by_findings =
      build_no_realized_by_findings(affected_subject_ids, subjects_by_id)

    raw_findings = verifier_report["findings"] || []
    findings = raw_findings ++ no_realized_by_findings
    findings_by_subject = group_findings_by_subject(findings)

    all_diffs = FileDiff.for_files(root, analysis.base, analysis.changed_files)

    claims_by_subject = group_claims_by_subject(verifier_report)

    # covers: specled.spec_review.coverage_tab_bind_closure
    # Per-requirement bind-closure reach: total MFAs, which closure files
    # were reached, by which tests. Degrades to a status atom when the
    # tracer manifest or coverage artifact is missing — the renderer
    # surfaces that as a "coverage artifact unavailable" message.
    closure_reach_opts = Keyword.get(opts, :closure_reach_opts, [])
    closure_reach_by_subject = CoverageClosure.build(index, closure_reach_opts)

    affected_subjects =
      Enum.flat_map(affected_subject_ids, fn id ->
        case Map.get(subjects_by_id, id) do
          nil ->
            []

          subject ->
            [
              build_subject_view(
                id,
                subject,
                analysis,
                all_diffs,
                findings_by_subject,
                root,
                Map.get(claims_by_subject, id, %{}),
                Map.get(closure_reach_by_subject, id, %{status: :ok, by_requirement: %{}})
              )
            ]
        end
      end)

    mapped_files = collect_mapped_files(affected_subjects)

    # covers: specled.spec_review.misc_panel
    # Files in the change set that don't map to any subject are surfaced
    # honestly here as flat file diffs rather than dropped from the view.
    unmapped_files =
      analysis.changed_files
      |> Enum.reject(&MapSet.member?(mapped_files, &1))
      |> Enum.reject(&policy_file?/1)
      |> Enum.sort()

    unmapped_changes =
      Enum.map(unmapped_files, fn path ->
        %{file: path, lines: Map.get(all_diffs, path, [])}
      end)

    file_breakdown = %{
      total: length(analysis.changed_files),
      mapped: MapSet.size(mapped_files),
      policy: Enum.count(analysis.changed_files, &policy_file?/1),
      unmapped: length(unmapped_files)
    }

    decisions_changed = build_decisions_changed(analysis, index)
    adrs_by_id = build_adrs_by_id(index, root, analysis.base)
    triage = build_triage(findings, affected_subjects, unmapped_changes != [], adrs_by_id)

    all_changes =
      analysis.changed_files
      |> Enum.sort()
      |> Enum.map(fn path -> %{file: path, lines: Map.get(all_diffs, path, [])} end)

    stats = compute_stats(all_changes)

    %{
      meta: %{
        base_ref: analysis.base,
        head_ref: head_ref(root),
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        verifier_status: verifier_report["status"],
        repo_root: root,
        stats: stats
      },
      triage: triage,
      affected_subjects: affected_subjects,
      unmapped_changes: unmapped_changes,
      decisions_changed: decisions_changed,
      adrs_by_id: adrs_by_id,
      all_findings: findings,
      all_changes: all_changes,
      file_breakdown: file_breakdown
    }
  end

  defp compute_stats(all_changes) do
    Enum.reduce(all_changes, %{files_changed: 0, additions: 0, deletions: 0}, fn %{lines: lines}, acc ->
      {adds, dels} =
        Enum.reduce(lines, {0, 0}, fn
          {:add, _}, {a, d} -> {a + 1, d}
          {:del, _}, {a, d} -> {a, d + 1}
          _, acc2 -> acc2
        end)

      touched? = adds > 0 or dels > 0

      %{
        files_changed: acc.files_changed + if(touched?, do: 1, else: 0),
        additions: acc.additions + adds,
        deletions: acc.deletions + dels
      }
    end)
  end

  defp build_adrs_by_id(index, root, base_ref) do
    (index["decisions"] || [])
    |> Map.new(fn decision ->
      meta = decision["meta"]
      id = meta_field(meta, :id, nil)
      file = decision["file"]
      title = decision["title"] || id

      data = %{
        id: id,
        file: file,
        title: title,
        status: meta_field(meta, :status, nil),
        date: meta_field(meta, :date, nil),
        change_type: meta_field(meta, :change_type, nil),
        affects: meta_field(meta, :affects, []),
        superseded_by: meta_field(meta, :superseded_by, nil),
        replaces: meta_field(meta, :replaces, nil),
        body_text: read_adr_body(root, file),
        change_status: SpecDiff.adr_change_status(root, base_ref, file)
      }

      {id, data}
    end)
  end

  defp read_adr_body(root, file) when is_binary(file) do
    case File.read(Path.join(root, file)) do
      {:ok, content} -> strip_frontmatter(content)
      _ -> ""
    end
  end

  defp read_adr_body(_root, _file), do: ""

  defp strip_frontmatter("---\n" <> rest) do
    case String.split(rest, "\n---\n", parts: 2) do
      [_frontmatter, body] -> String.trim_leading(body, "\n")
      _ -> rest
    end
  end

  defp strip_frontmatter(content), do: content

  defp subjects_by_id(index) do
    (index["subjects"] || [])
    |> Map.new(fn subject -> {Coverage.subject_id(subject), subject} end)
  end

  # covers: specled.spec_review.spec_first_navigation
  # The view-model is keyed on subject id with the prose statement front and
  # center; the renderer treats each affected_subject entry as the primary
  # navigation unit, never the underlying file paths.
  defp build_subject_view(
         id,
         subject,
         analysis,
         all_diffs,
         findings_by_subject,
         root,
         claims_by_req,
         closure_reach
       ) do
    meta = subject["meta"]
    statement = meta_field(meta, :summary, "")
    title = subject["title"] || id
    file = subject["file"]

    subject_files = Map.get(analysis.subject_file_map, id, MapSet.new())

    changed_files =
      analysis.changed_files
      |> Enum.filter(&MapSet.member?(subject_files, &1))
      |> Enum.sort()

    code_changes =
      Enum.map(changed_files, fn path ->
        %{file: path, lines: Map.get(all_diffs, path, [])}
      end)

    spec_file_changed? = is_binary(file) and file in analysis.changed_files

    spec_diff =
      if spec_file_changed? do
        %{file: file, lines: Map.get(all_diffs, file, [])}
      else
        nil
      end

    spec_changes =
      if spec_file_changed? do
        SpecDiff.compute(root, analysis.base, subject)
      else
        empty_spec_changes()
      end

    %{
      id: id,
      file: file,
      title: title,
      statement: statement,
      bindings: meta_field(meta, :realized_by, %{}),
      decision_refs: meta_field(meta, :decisions, []),
      requirements: subject["requirements"] || [],
      scenarios: subject["scenarios"] || [],
      verification: subject["verification"] || [],
      code_changes: code_changes,
      spec_diff: spec_diff,
      spec_changes: spec_changes,
      findings: Map.get(findings_by_subject, id, []),
      claims_by_req: claims_by_req,
      closure_reach: closure_reach,
      changed_files: changed_files
    }
  end

  defp group_claims_by_subject(verifier_report) do
    claims =
      verifier_report
      |> Map.get("verification", %{})
      |> Map.get("claims", [])

    claims
    |> Enum.group_by(& &1["subject_id"])
    |> Map.new(fn {sid, sub_claims} ->
      grouped = Enum.group_by(sub_claims, & &1["cover_id"])
      {sid, grouped}
    end)
  end

  defp empty_spec_changes do
    %{
      file_changed?: false,
      base_existed?: true,
      requirements: %{added: [], modified: [], removed: [], unchanged_ids: MapSet.new()},
      scenarios: %{added: [], modified: [], removed: [], unchanged_ids: MapSet.new()}
    }
  end

  defp meta_field(nil, _key, default), do: default
  defp meta_field(meta, key, default) when is_struct(meta), do: Map.get(meta, key) || default
  defp meta_field(meta, key, default) when is_map(meta) do
    Map.get(meta, key) || Map.get(meta, Atom.to_string(key)) || default
  end

  defp collect_mapped_files(affected_subjects) do
    affected_subjects
    |> Enum.flat_map(& &1.changed_files)
    |> MapSet.new()
  end

  defp policy_file?(path) do
    String.starts_with?(path, ".spec/specs/") or String.starts_with?(path, ".spec/decisions/")
  end

  defp build_triage(findings, affected_subjects, has_unmapped?, adrs_by_id) do
    by_severity =
      findings
      |> Enum.group_by(& &1["severity"])
      |> Map.new(fn {sev, items} -> {sev, length(items)} end)

    affected_summaries =
      Enum.map(affected_subjects, fn s ->
        sev_counts =
          s.findings
          |> Enum.group_by(& &1["severity"])
          |> Map.new(fn {sev, items} -> {sev, length(items)} end)

        %{
          id: s.id,
          findings_count: length(s.findings),
          by_severity: sev_counts,
          change_status: subject_change_status(s.spec_changes)
        }
      end)

    requirement_count =
      affected_subjects
      |> Enum.map(&length(&1.requirements))
      |> Enum.sum()

    binding_count =
      affected_subjects
      |> Enum.flat_map(fn s -> Map.values(s.bindings || %{}) end)
      |> Enum.flat_map(&List.wrap/1)
      |> length()

    verification_count =
      affected_subjects
      |> Enum.map(&length(&1.verification || []))
      |> Enum.sum()

    adr_refs =
      affected_subjects
      |> Enum.flat_map(& &1.decision_refs)
      |> Enum.uniq()

    unresolved_adr_refs = Enum.reject(adr_refs, &Map.has_key?(adrs_by_id, &1))

    strength_breakdown =
      affected_subjects
      |> Enum.flat_map(fn s ->
        Enum.map(s.requirements, fn req ->
          id = req_id(req)
          claims = Map.get(s.claims_by_req || %{}, id, [])
          best_claim_strength(claims)
        end)
      end)
      |> Enum.frequencies()

    findings_by_code =
      findings
      |> Enum.group_by(& &1["code"])
      |> Map.new(fn {k, v} -> {k, length(v)} end)

    detector_unavailable_by_leg = build_detector_unavailable_by_leg(findings)

    %{
      findings_count: length(findings),
      by_severity: by_severity,
      affected_subject_count: length(affected_subjects),
      affected_subjects: affected_summaries,
      has_unmapped_changes?: has_unmapped?,
      clean?: findings == [] and not has_unmapped? and affected_subjects == [],
      requirement_count: requirement_count,
      binding_count: binding_count,
      verification_count: verification_count,
      adr_ref_count: length(adr_refs),
      unresolved_adr_count: length(unresolved_adr_refs),
      strength_breakdown: strength_breakdown,
      findings_by_code: findings_by_code,
      detector_unavailable_by_leg: detector_unavailable_by_leg
    }
  end

  # Aggregate `detector_unavailable` findings into the triangle leg they
  # belong to, keyed by reason. Realization-tier detectors
  # (`debug_info_stripped`, `umbrella_unsupported` from any realization
  # tier) live on SPEC ↔ CODE; coverage triangulation's
  # `no_coverage_artifact` lives on CODE ↔ TESTS (the evidence leg).
  # Reasons we don't recognize land on `:unknown` so they aren't silently
  # dropped — the renderer surfaces them under the closest leg.
  defp build_detector_unavailable_by_leg(findings) do
    findings
    |> Enum.filter(&(&1["code"] == "detector_unavailable"))
    |> Enum.reduce(%{}, fn finding, acc ->
      reason = finding["reason"] || "unknown"
      leg = detector_unavailable_leg(reason)

      Map.update(acc, leg, %{reason => 1}, fn by_reason ->
        Map.update(by_reason, reason, 1, &(&1 + 1))
      end)
    end)
  end

  # Reasons emitted by realization tiers (expanded_behavior, use_tier,
  # typespecs, api_boundary, implementation) live on SPEC ↔ CODE — the
  # `realized_by` leg. The coverage triangulation's `no_coverage_artifact`
  # lives on CODE ↔ TESTS — the evidence leg. `no_realized_by` (synthesized
  # by `build_no_realized_by_findings/2`) is the absence of any binding at
  # all, which lives on SPEC ↔ CODE for the same reason as the tier-level
  # reasons: there is nothing the realization detectors can verify.
  defp detector_unavailable_leg("debug_info_stripped"), do: :spec_to_code
  defp detector_unavailable_leg("umbrella_unsupported"), do: :spec_to_code
  defp detector_unavailable_leg("no_realized_by"), do: :spec_to_code
  defp detector_unavailable_leg("no_coverage_artifact"), do: :tests_to_coverage
  defp detector_unavailable_leg(_), do: :spec_to_code

  # covers: specled.spec_review.no_realized_by_degrades_spec_to_code
  # Synthesize one `detector_unavailable` finding (reason `no_realized_by`)
  # per affected subject whose `spec-meta.realized_by` declares no bindings.
  # These findings flow through the same plumbing as tier-emitted detector
  # unavailables: they group per-subject, contribute to the triage panel's
  # `detector_unavailable_by_leg` aggregation, and surface the SPEC ↔ CODE
  # leg as :degraded with a reviewer-visible reason.
  defp build_no_realized_by_findings(affected_subject_ids, subjects_by_id) do
    Enum.flat_map(affected_subject_ids, fn id ->
      case Map.get(subjects_by_id, id) do
        nil ->
          []

        subject ->
          if subject_has_realized_by?(subject) do
            []
          else
            [no_realized_by_finding(id, subject_file(subject))]
          end
      end
    end)
  end

  defp subject_has_realized_by?(subject) do
    meta = subject["meta"] || Map.get(subject, :meta) || %{}
    subject_rb = realized_by_map(meta)

    if realized_by_has_binding?(subject_rb) do
      true
    else
      reqs = subject["requirements"] || Map.get(subject, :requirements, []) || []

      Enum.any?(List.wrap(reqs), fn req ->
        req |> realized_by_map() |> realized_by_has_binding?()
      end)
    end
  end

  defp realized_by_map(nil), do: %{}

  defp realized_by_map(container) when is_map(container) do
    case Map.get(container, :realized_by) || Map.get(container, "realized_by") do
      %{} = rb -> rb
      _ -> %{}
    end
  end

  defp realized_by_map(_), do: %{}

  defp realized_by_has_binding?(rb) when is_map(rb) and map_size(rb) == 0, do: false

  defp realized_by_has_binding?(rb) when is_map(rb) do
    rb
    |> Map.values()
    |> Enum.any?(fn v -> v |> List.wrap() |> Enum.any?(&(&1 not in [nil, ""])) end)
  end

  defp realized_by_has_binding?(_), do: false

  defp subject_file(subject), do: subject["file"] || Map.get(subject, :file)

  defp no_realized_by_finding(subject_id, file) do
    base = %{
      "code" => "detector_unavailable",
      "severity" => "info",
      "reason" => "no_realized_by",
      "subject_id" => subject_id,
      "message" =>
        "This subject declares no `realized_by` bindings — the SPEC ↔ CODE leg cannot be verified. Add a `realized_by:` block under `spec-meta` or on individual requirements to enable realization checks."
    }

    if is_binary(file), do: Map.put(base, "file", file), else: base
  end

  defp req_id(req) when is_struct(req), do: to_string(Map.get(req, :id) || "")
  defp req_id(req) when is_map(req), do: to_string(Map.get(req, :id) || Map.get(req, "id") || "")
  defp req_id(_), do: ""

  defp best_claim_strength([]), do: :uncovered

  defp best_claim_strength(claims) do
    strengths = Enum.map(claims, & &1["strength"])

    cond do
      "executed" in strengths -> :executed
      "linked" in strengths -> :linked
      "claimed" in strengths -> :claimed
      true -> :uncovered
    end
  end

  defp subject_change_status(%{base_existed?: false}), do: :new
  defp subject_change_status(%{file_changed?: true}), do: :edited
  defp subject_change_status(_), do: :code_only

  defp group_findings_by_subject(findings) do
    findings
    |> List.wrap()
    |> Enum.group_by(& &1["subject_id"])
  end

  defp build_decisions_changed(analysis, index) do
    decision_files = Enum.filter(analysis.changed_files, &ChangeAnalysis.decision_file?/1)
    decisions_by_file = Map.new(index["decisions"] || [], &{&1["file"], &1})

    Enum.map(decision_files, fn file ->
      case Map.get(decisions_by_file, file) do
        nil ->
          %{id: nil, file: file, status: nil, change_type: nil, affects: []}

        decision ->
          meta = decision["meta"] || %{}

          %{
            id: meta["id"],
            file: file,
            status: meta["status"],
            change_type: meta["change_type"],
            affects: meta["affects"] || []
          }
      end
    end)
  end

  defp head_ref(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> "HEAD"
    end
  end
end
