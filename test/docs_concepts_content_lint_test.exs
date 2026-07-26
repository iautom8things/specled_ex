defmodule SpecLedEx.DocsConceptsContentLintTest do
  use ExUnit.Case, async: true

  @concepts_path "docs/concepts.md"

  @tag spec: "specled.package.concepts_guide"
  test "concepts guide preserves the required spec-triangle, tier, degrade, and drift clauses" do
    concepts = File.read!(@concepts_path)

    assert_contains_all(concepts, "spec triangle", [
      "## The triangle",
      "Specs ↔ Code",
      "Specs ↔ Tests",
      "Code ↔ Tests"
    ])

    assert_contains_all(concepts, "realized_by tiers", [
      "## The five tiers",
      "`api_boundary`",
      "`implementation`",
      "`expanded_behavior`",
      "`use`",
      "`typespecs`"
    ])

    assert_contains_all(concepts, "graceful-degrade detector_unavailable rule", [
      "**Graceful degrade is first-class.**",
      "`detector_unavailable`",
      "tier silently skips",
      "partial data."
    ])

    assert_contains_all(concepts, "intentional drift acceptance paths", [
      "**`mix spec.check --accept-drift`**",
      "**`Spec-Drift: branch_guard_realization_drift=info` trailer**",
      "**Delete-and-reseed**"
    ])

    assert_contains(concepts, "mix spec.check verdict read protocol", "spec.check result=")
  end

  defp assert_contains_all(content, clause, needles) do
    missing = Enum.reject(needles, &String.contains?(content, &1))

    assert missing == [],
           "docs/concepts.md is missing #{clause} content:\n" <>
             Enum.map_join(missing, "\n", &"  - #{&1}")
  end

  defp assert_contains(content, clause, needle) do
    assert String.contains?(content, needle),
           "docs/concepts.md is missing #{clause} content: #{inspect(needle)}"
  end
end
