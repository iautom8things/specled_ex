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
      "| `api_boundary`        | Function head, arity, arg pattern shape, literal default arguments.",
      "| `implementation`      | Transitive call closure of the declared MFAs, bounded by subject ownership.",
      "| `expanded_behavior`   | Post-macro-expansion AST from `:beam_lib.chunks(..., [:debug_info])`.",
      "| `use`                 | Provider's `expanded_behavior` hash + sorted consumer module list.",
      "| `typespecs`           | Sorted `@spec` / `@type` declarations."
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
  end

  defp assert_contains_all(content, clause, needles) do
    missing = Enum.reject(needles, &String.contains?(content, &1))

    assert missing == [],
           "docs/concepts.md is missing #{clause} content:\n" <>
             Enum.map_join(missing, "\n", &"  - #{&1}")
  end
end
