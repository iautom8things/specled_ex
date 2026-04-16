defmodule SpecLedEx.BranchCheck do
  @moduledoc false

  alias SpecLedEx.ChangeAnalysis

  def run(index, root, opts \\ []) do
    analysis = ChangeAnalysis.analyze(index, root, opts)
    changed_subject_ids = MapSet.new(analysis.changed_subject_ids)

    file_findings =
      Enum.flat_map(analysis.policy_files, fn path ->
        impacted_subjects = Map.get(analysis.impacted_by_file, path, []) |> MapSet.new()

        cond do
          MapSet.size(impacted_subjects) == 0 and
              ChangeAnalysis.ignorable_deleted_policy_file?(root, path, changed_subject_ids) ->
            []

          MapSet.size(impacted_subjects) == 0 ->
            [
              finding(
                "error",
                "branch_guard_unmapped_change",
                "Changed file is not covered by any current-truth subject: #{path}",
                path
              )
            ]

          true ->
            missing_subject_ids =
              impacted_subjects
              |> MapSet.difference(changed_subject_ids)
              |> MapSet.to_list()
              |> Enum.sort()

            if missing_subject_ids == [] do
              []
            else
              [
                finding(
                  "error",
                  "branch_guard_missing_subject_update",
                  "Changed file #{path} impacts subject specs that were not updated: #{Enum.join(missing_subject_ids, ", ")}",
                  path
                )
              ]
            end
        end
      end)

    impacted_subjects = analysis.impacted_subject_ids |> MapSet.new()

    governance_findings =
      if needs_decision_update?(analysis.policy_files, impacted_subjects) and
           not analysis.decision_changed? do
        [
          finding(
            "error",
            "branch_guard_missing_decision_update",
            "Cross-cutting change spans multiple subjects but no decision file changed",
            nil
          )
        ]
      else
        []
      end

    tag_findings = new_requirement_tag_findings(index, analysis, root)

    findings =
      Enum.sort_by(
        file_findings ++ governance_findings ++ tag_findings,
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

  defp new_requirement_tag_findings(index, analysis, root) do
    case Map.get(index, "test_tags") do
      nil ->
        []

      tag_map when is_map(tag_map) ->
        severity = severity_from_config(Map.get(index, "test_tags_config"))
        subjects_by_file = subjects_by_file(index)

        analysis.changed_files
        |> Enum.filter(&spec_file?/1)
        |> Enum.flat_map(fn path ->
          subject = Map.get(subjects_by_file, path)

          if subject do
            subject_id = subject_id(subject)
            current_ids = must_ids_from_subject(subject)
            base_ids = base_must_ids(root, analysis.base, path)
            new_ids = current_ids -- base_ids

            new_ids
            |> Enum.reject(&Map.has_key?(tag_map, &1))
            |> Enum.map(fn id ->
              finding(
                severity,
                "branch_guard_requirement_without_test_tag",
                "New must requirement has no backing @tag spec annotation: #{id}",
                path,
                subject_id
              )
            end)
          else
            []
          end
        end)
    end
  end

  defp severity_from_config(%{"enforcement" => "error"}), do: "error"
  defp severity_from_config(_), do: "warning"

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
    ~r/```spec-requirements\s*\n(.*?)\n```/ms
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.flat_map(fn [block] ->
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
    end)
  end

  defp spec_file?(path), do: String.starts_with?(path, ".spec/specs/") and String.ends_with?(path, ".spec.md")

  defp finding(severity, code, message, file) do
    %{
      "severity" => severity,
      "code" => code,
      "message" => message,
      "file" => file
    }
  end

  defp finding(severity, code, message, file, subject_id) do
    severity
    |> finding(code, message, file)
    |> Map.put("subject_id", subject_id)
  end
end
