defmodule SpecLedEx.Diffcheck do
  @moduledoc false

  alias SpecLedEx.Coverage

  @decision_pattern ~r/^\.spec\/decisions\/.+\.md$/

  def run(index, root, opts \\ []) do
    changed_files = changed_files(root, opts[:base])
    subject_file_map = Coverage.subject_file_map(index, root)
    changed_subject_ids = changed_subject_ids(index, changed_files)
    decision_changed? = Enum.any?(changed_files, &decision_file?/1)
    policy_files = Enum.filter(changed_files, &policy_target?/1)

    file_findings =
      Enum.flat_map(policy_files, fn path ->
        impacted_subjects = Coverage.subject_ids_for_path(subject_file_map, path)

        cond do
          MapSet.size(impacted_subjects) == 0 ->
            [finding("error", "diffcheck_unmapped_change", "Changed file is not covered by any current-truth subject: #{path}", path)]

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
                  "diffcheck_missing_spec_update",
                  "Changed file #{path} impacts subject specs that were not updated: #{Enum.join(missing_subject_ids, ", ")}",
                  path
                )
              ]
            end
        end
      end)

    impacted_subjects =
      policy_files
      |> Enum.reduce(MapSet.new(), fn path, acc ->
        MapSet.union(acc, Coverage.subject_ids_for_path(subject_file_map, path))
      end)

    governance_findings =
      if needs_decision_update?(policy_files, impacted_subjects) and not decision_changed? do
        [
          finding(
            "warning",
            "diffcheck_missing_decision_update",
            "Cross-cutting change spans multiple subjects but no decision file changed",
            nil
          )
        ]
      else
        []
      end

    findings = Enum.sort_by(file_findings ++ governance_findings, &{&1["code"], &1["file"] || "", &1["message"]})

    %{
      "base" => detect_base_ref(root, opts[:base]),
      "changed_files" => changed_files,
      "status" => if(findings == [], do: "pass", else: "fail"),
      "summary" => %{
        "changed_files" => length(changed_files),
        "policy_files" => length(policy_files),
        "findings" => length(findings)
      },
      "findings" => findings
    }
  end

  defp changed_subject_ids(index, changed_files) do
    changed_files = MapSet.new(changed_files)

    index["subjects"]
    |> List.wrap()
    |> Enum.reduce(MapSet.new(), fn subject, acc ->
      if MapSet.member?(changed_files, subject["file"]) do
        MapSet.put(acc, Coverage.subject_id(subject))
      else
        acc
      end
    end)
  end

  defp needs_decision_update?(policy_files, impacted_subjects) do
    length(policy_files) > 1 and MapSet.size(impacted_subjects) > 1
  end

  defp policy_target?(path) do
    String.starts_with?(path, "lib/") or
      String.starts_with?(path, "test/") or
      String.starts_with?(path, "guides/") or
      String.starts_with?(path, "docs/") or
      path in ~w(README.md AGENTS.md CHANGELOG.md mix.exs)
  end

  defp decision_file?(path) do
    Regex.match?(@decision_pattern, path) and Path.basename(path) != "README.md"
  end

  defp changed_files(root, explicit_base) do
    base = detect_base_ref(root, explicit_base)

    [diff_against_base(root, base), working_tree_diff(root), staged_diff(root), untracked_files(root)]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp detect_base_ref(_root, explicit_base) when is_binary(explicit_base), do: explicit_base

  defp detect_base_ref(root, nil) do
    Enum.find(["origin/main", "main", "master", "HEAD"], &git_ref_exists?(root, &1)) || "HEAD"
  end

  defp diff_against_base(root, base) do
    git_lines(root, ["diff", "--name-only", "#{base}...HEAD"])
  end

  defp working_tree_diff(root) do
    git_lines(root, ["diff", "--name-only"])
  end

  defp staged_diff(root) do
    git_lines(root, ["diff", "--cached", "--name-only"])
  end

  defp untracked_files(root) do
    git_lines(root, ["ls-files", "--others", "--exclude-standard"])
  end

  defp git_ref_exists?(root, ref) do
    {_output, exit_code} = System.cmd("git", ["-C", root, "rev-parse", "--verify", ref], stderr_to_stdout: true)
    exit_code == 0
  end

  defp git_lines(root, args) do
    {output, exit_code} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)

    if exit_code == 0 do
      String.split(output, "\n", trim: true)
    else
      raise "git command failed: git #{Enum.join(args, " ")}\n#{String.trim(output)}"
    end
  end

  defp finding(severity, code, message, file) do
    %{
      "severity" => severity,
      "code" => code,
      "message" => message,
      "file" => file
    }
  end
end
