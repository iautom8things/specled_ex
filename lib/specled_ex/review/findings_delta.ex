defmodule SpecLedEx.Review.FindingsDelta do
  @moduledoc """
  Differential findings classification for the Overview pane.

  Classifies head-side findings against the committed verification state at the
  base ref: `introduced` (present at head, absent at base), `resolved` (present
  at base, absent at head), and `pre_existing` (present at both). The change
  verdict is driven by `introduced` findings only.

  Base findings are read from the committed `.spec/state.json` at the base ref
  (`git show <base>:.spec/state.json`) — never recomputed by re-running the
  verifier at base. When that committed state is absent or unparseable the
  classification degrades to a non-differential fallback
  (`delta_available?: false`): a finding is never presented as introduced by the
  change when base attribution is unavailable.
  """

  @state_path ".spec/state.json"

  @doc """
  Classify `head_findings` against the base ref's committed findings.

  Returns a map with `:delta_available?`, the `:introduced` / `:resolved` /
  `:pre_existing` lists, `:base_reason` (nil when differential, otherwise the
  reason the fallback was taken), and a `:change_verdict`.
  """
  def classify(root, base_ref, head_findings) do
    case load_base_findings(root, base_ref) do
      {:ok, base_findings} -> differential(base_findings, head_findings)
      {:error, reason} -> fallback(reason, head_findings)
    end
  end

  defp differential(base_findings, head_findings) do
    base_sigs = MapSet.new(base_findings, &signature/1)
    head_sigs = MapSet.new(head_findings, &signature/1)

    {pre_existing, introduced} =
      Enum.split_with(head_findings, &MapSet.member?(base_sigs, signature(&1)))

    resolved = Enum.reject(base_findings, &MapSet.member?(head_sigs, signature(&1)))

    %{
      delta_available?: true,
      base_reason: nil,
      introduced: introduced,
      resolved: resolved,
      pre_existing: pre_existing,
      change_verdict: differential_verdict(introduced)
    }
  end

  defp fallback(reason, _head_findings) do
    %{
      delta_available?: false,
      base_reason: reason,
      introduced: [],
      resolved: [],
      pre_existing: [],
      change_verdict: non_differential_verdict()
    }
  end

  # A finding's identity across the two on-disk shapes: the committed base
  # findings are normalized (`entity_id` / `level`) while the head findings
  # carry the live verifier shape (`subject_id` / `severity`). Identity is the
  # (code, entity, file, message) tuple — severity is an attribute of a
  # finding, not part of its identity, so a severity override does not make a
  # pre-existing finding read as introduced.
  defp signature(finding) do
    {
      finding["code"],
      finding["subject_id"] || finding["entity_id"],
      finding["file"],
      finding["message"]
    }
  end

  defp differential_verdict(introduced) do
    %{
      differential?: true,
      clean?: introduced == [],
      introduced_count: length(introduced),
      by_severity: severity_counts(introduced)
    }
  end

  defp non_differential_verdict do
    %{
      differential?: false,
      clean?: nil,
      introduced_count: nil,
      by_severity: %{}
    }
  end

  defp severity_counts(findings) do
    findings
    |> Enum.group_by(&(&1["severity"] || &1["level"]))
    |> Map.new(fn {sev, items} -> {sev, length(items)} end)
  end

  defp load_base_findings(_root, base_ref) when base_ref in [nil, ""],
    do: {:error, :base_state_absent}

  defp load_base_findings(root, base_ref) do
    case git_show_state(root, base_ref) do
      {:ok, content} -> parse_findings(content)
      :error -> {:error, :base_state_absent}
    end
  end

  defp parse_findings(content) do
    case Jason.decode(content) do
      {:ok, %{"findings" => findings}} when is_list(findings) -> {:ok, findings}
      {:ok, %{}} -> {:ok, []}
      _ -> {:error, :base_state_unparseable}
    end
  end

  defp git_show_state(root, base_ref) do
    case System.cmd("git", ["-C", root, "show", "#{base_ref}:#{@state_path}"],
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {_out, _nonzero} -> :error
    end
  end
end
