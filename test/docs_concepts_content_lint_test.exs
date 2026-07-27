defmodule SpecLedEx.DocsConceptsContentLintTest do
  # async-safety: File.read!/1 below uses a relative path against the
  # VM-global cwd (File.cwd!/0). Safe here because the suite's only
  # File.cd!/1 lives in an async: false module
  # (test/specled_ex/realization/binding_test.exs), and ExUnit never
  # overlaps async and sync modules.
  use ExUnit.Case, async: true

  @concepts_path "docs/concepts.md"

  @tag spec: "specled.package.concepts_guide"
  test "concepts guide preserves the required spec-triangle clauses" do
    concepts = File.read!(@concepts_path)

    assert_contains_all(concepts, "spec triangle", [
      "## The triangle",
      "Specs ↔ Code",
      "Specs ↔ Tests",
      "Code ↔ Tests"
    ])
  end

  @tag spec: "specled.package.concepts_guide"
  test "concepts guide preserves the required realized_by tier clauses" do
    concepts = File.read!(@concepts_path)

    # Needles keep full row content (tier token + prose) so bare backticked
    # tokens cannot match elsewhere in the document. assert_contains_all/3
    # collapses [ \t]+ runs in both haystack and needles so re-padding the
    # table stays green while deleting a tier row still goes red.
    assert_contains_all(concepts, "realized_by tiers", [
      "## The five tiers",
      "| `api_boundary`        | Function head, arity, arg pattern shape, literal default arguments.",
      "| `implementation`      | Transitive call closure of the declared MFAs, bounded by subject ownership.",
      "| `expanded_behavior`   | Post-macro-expansion AST from `:beam_lib.chunks(..., [:debug_info])`.",
      "| `use`                 | Provider's `expanded_behavior` hash + sorted consumer module list.",
      "| `typespecs`           | Sorted `@spec` / `@type` declarations."
    ])
  end

  @tag spec: "specled.package.concepts_guide"
  test "concepts guide preserves the required graceful-degrade clauses" do
    concepts = File.read!(@concepts_path)

    assert_contains_all(concepts, "graceful-degrade detector_unavailable rule", [
      "**Graceful degrade is first-class.**",
      "`detector_unavailable`",
      "tier silently skips",
      "partial data."
    ])
  end

  @tag spec: "specled.package.concepts_guide"
  test "concepts guide preserves the required intentional drift clauses" do
    concepts = File.read!(@concepts_path)

    assert_contains_all(concepts, "intentional drift acceptance paths", [
      "**`mix spec.check --accept-drift`**",
      "**`Spec-Drift: branch_guard_realization_drift=info` trailer**",
      "**Delete-and-reseed**"
    ])
  end

  defp assert_contains_all(content, clause, needles) do
    assert needles != [], "#{clause}: empty needle list — the clause guard is vacuous"

    content = collapse_ws(content)
    needles = Enum.map(needles, &collapse_ws/1)
    missing = Enum.reject(needles, &String.contains?(content, &1))

    assert missing == [],
           "#{@concepts_path} is missing #{clause} content:\n" <>
             Enum.map_join(missing, "\n", &"  - #{&1}")
  end

  defp collapse_ws(string), do: String.replace(string, ~r/[ \t]+/, " ")
end
