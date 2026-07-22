defmodule SpecLedEx.Review.FindingsDelta do
  @moduledoc """
  Differential findings classification for the Overview pane.

  Classifies head-side findings against the stored verification evidence for
  the base tree: `introduced` (present at head, absent at base), `resolved` (present
  at base, absent at head), and `pre_existing` (present at both). The change
  verdict is driven by `introduced` findings only.

  Base findings are read from the evidence store entry keyed by
  `git rev-parse <base>^{tree}` — never recomputed by re-running the verifier at
  base. When that base tree or its stored evidence is unavailable the
  classification degrades to a non-differential fallback
  (`delta_available?: false`): a finding is never presented as introduced by the
  change when base attribution is unavailable.

  The head-side findings this module classifies are not all attested by the
  same producer that seeds the evidence store: `mix spec.check` never
  computes or records the review-only `detector_unavailable` finding with
  reason `no_realized_by` (synthesized by `Review.build_view/3` for subjects
  that declare no `realized_by` bindings), so no base evidence entry can ever
  contain it. Comparing it against base as if it could would misclassify a
  subject's static, pre-existing lack of bindings as introduced by every
  change that merely touches that subject. This module treats any such
  producer-incomparable finding as always pre-existing — never introduced,
  never resolved.
  """

  alias SpecLedEx.Evidence.{Store, TreeHash}

  @doc """
  Classify `head_findings` against the base tree's stored findings.

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
    {synthetic, comparable} = Enum.split_with(head_findings, &producer_incomparable?/1)

    base_sigs = MapSet.new(base_findings, &signature/1)
    head_sigs = MapSet.new(comparable, &signature/1)

    {pre_existing, introduced} =
      Enum.split_with(comparable, &MapSet.member?(base_sigs, signature(&1)))

    resolved = Enum.reject(base_findings, &MapSet.member?(head_sigs, signature(&1)))

    %{
      delta_available?: true,
      base_reason: nil,
      introduced: introduced,
      resolved: resolved,
      pre_existing: pre_existing ++ synthetic,
      change_verdict: differential_verdict(introduced)
    }
  end

  # `mix spec.check` is the sole producer that seeds base evidence, and it
  # never computes the review-only `no_realized_by` synthetic finding (see
  # `Review.build_no_realized_by_findings/2`) — that finding exists only
  # inside the review artifact's own view-model build. Absence at base is
  # therefore not evidence of anything the change did; it's absence of a
  # producer that could ever have recorded it. Every other `detector_unavailable`
  # reason (`debug_info_stripped`, `umbrella_unsupported`, `no_coverage_artifact`,
  # …) is emitted by `Verifier.verify/3` itself, the same producer `mix
  # spec.check` runs, so those stay in the normal comparable set.
  defp producer_incomparable?(finding) do
    finding["code"] == "detector_unavailable" and finding["reason"] == "no_realized_by"
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
    do: {:error, :base_tree_unresolvable}

  defp load_base_findings(root, base_ref) do
    with {:ok, tree_hash} <- TreeHash.base(root, base_ref) do
      case Store.read(root, tree_hash) do
        {:ok, %{"findings" => findings}} when is_list(findings) -> {:ok, findings}
        {:ok, %{}} -> {:ok, []}
        :absent -> {:error, :base_evidence_absent}
        {:error, _reason} -> {:error, :base_evidence_absent}
      end
    else
      {:error, _reason} -> {:error, :base_tree_unresolvable}
    end
  end
end
