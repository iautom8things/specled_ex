defmodule SpecLedEx.Review do
  @moduledoc """
  Assembles the view-model rendered as the spec-aware PR review HTML.

  The renderer (`SpecLedEx.Review.Html`) is intentionally dumb — it expects
  the view-model returned by `build_view/3` and does no further data
  fetching. All git interaction, finding aggregation, and per-subject
  grouping happens here.
  """

  alias SpecLedEx.{ChangeAnalysis, Coverage, Verifier}
  alias SpecLedEx.Review.{FileDiff, SpecDiff}

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
    verifier_opts = Keyword.drop(opts, [:base])
    verifier_report = Verifier.verify(index, root, verifier_opts)

    subjects_by_id = subjects_by_id(index)
    findings_by_subject = group_findings_by_subject(verifier_report["findings"])

    affected_subject_ids =
      MapSet.union(
        MapSet.new(analysis.changed_subject_ids),
        MapSet.new(analysis.impacted_subject_ids)
      )
      |> MapSet.to_list()
      |> Enum.sort()

    all_diffs = FileDiff.for_files(root, analysis.base, analysis.changed_files)

    claims_by_subject = group_claims_by_subject(verifier_report)

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
                Map.get(claims_by_subject, id, %{})
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

    decisions_changed = build_decisions_changed(analysis, index)
    findings = verifier_report["findings"] || []
    triage = build_triage(findings, affected_subjects, unmapped_changes != [])
    adrs_by_id = build_adrs_by_id(index, root, analysis.base)

    %{
      meta: %{
        base_ref: analysis.base,
        head_ref: head_ref(root),
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
        verifier_status: verifier_report["status"],
        repo_root: root
      },
      triage: triage,
      affected_subjects: affected_subjects,
      unmapped_changes: unmapped_changes,
      decisions_changed: decisions_changed,
      adrs_by_id: adrs_by_id,
      all_findings: findings
    }
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
         claims_by_req
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

  defp build_triage(findings, affected_subjects, has_unmapped?) do
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
          by_severity: sev_counts
        }
      end)

    %{
      findings_count: length(findings),
      by_severity: by_severity,
      affected_subject_count: length(affected_subjects),
      affected_subjects: affected_summaries,
      has_unmapped_changes?: has_unmapped?,
      clean?: findings == [] and not has_unmapped? and affected_subjects == []
    }
  end

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
