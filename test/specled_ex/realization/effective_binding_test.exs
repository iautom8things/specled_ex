defmodule SpecLedEx.Realization.EffectiveBindingTest do
  use ExUnit.Case, async: true
  @moduletag spec: [
                "specled.realized_by.effective_binding_inherits_subject",
                "specled.realized_by.effective_binding_requirement_replaces_tier",
                "specled.realized_by.effective_binding_accepts_subject_shape",
                "specled.realized_by.implication_one_way",
                "specled.realized_by.implication_invoked_per_layer"
              ]

  alias SpecLedEx.Realization.EffectiveBinding

  describe "for_requirement/2" do
    test "inherits subject-level binding when requirement has none" do
      subject = %{realized_by: %{"api_boundary" => ["MyMod.a/1", "MyMod.b/2"]}}
      requirement = %{realized_by: nil}

      assert EffectiveBinding.for_requirement(subject, requirement) ==
               %{"api_boundary" => ["MyMod.a/1", "MyMod.b/2"]}
    end

    test "requirement-level replaces subject-level per tier" do
      subject = %{
        realized_by: %{
          "api_boundary" => ["MyMod.a/1"],
          "implementation" => ["MyMod.a/1"]
        }
      }

      requirement = %{realized_by: %{"api_boundary" => ["MyMod.c/3"]}}

      merged = EffectiveBinding.for_requirement(subject, requirement)

      assert merged == %{
               "api_boundary" => ["MyMod.c/3"],
               "implementation" => ["MyMod.a/1"]
             }
    end

    test "returns empty map when neither layer declares a binding" do
      assert EffectiveBinding.for_requirement(%{}, %{}) == %{}
      assert EffectiveBinding.for_requirement(%{realized_by: nil}, %{realized_by: nil}) == %{}
    end

    test "accepts string-keyed realized_by (from JSON/map input)" do
      subject = %{"realized_by" => %{"api_boundary" => ["A.a/1"]}}
      requirement = %{"realized_by" => %{"implementation" => ["A.a/1"]}}

      assert EffectiveBinding.for_requirement(subject, requirement) == %{
               "api_boundary" => ["A.a/1"],
               "implementation" => ["A.a/1"]
             }
    end

    test "atom tier keys are normalized to strings" do
      subject = %{realized_by: %{api_boundary: ["A.a/1"]}}

      assert EffectiveBinding.for_requirement(subject, %{}) == %{"api_boundary" => ["A.a/1"]}
    end

    test "accepts a parsed-subject map with realized_by nested under meta" do
      # Shape produced by SpecLedEx.Parser for a whole .spec.md file:
      # the spec-meta block lives at subject["meta"], so realized_by is at
      # subject["meta"]["realized_by"], not at the top level.
      subject = %{
        "file" => "subj.spec.md",
        "meta" => %{
          "id" => "demo",
          "realized_by" => %{"implementation" => ["A.a/1"]}
        },
        "requirements" => []
      }

      requirement = %{"id" => "demo.req"}

      assert EffectiveBinding.for_requirement(subject, requirement) ==
               %{"implementation" => ["A.a/1"]}
    end

    test "top-level realized_by takes precedence over nested meta" do
      subject = %{
        :realized_by => %{"implementation" => ["TopLevel.a/1"]},
        "meta" => %{"realized_by" => %{"implementation" => ["Nested.a/1"]}}
      }

      assert EffectiveBinding.for_requirement(subject, %{}) ==
               %{"implementation" => ["TopLevel.a/1"]}
    end
  end

  describe "expand_implications/1" do
    # covers: specled.realized_by.implication_one_way
    test "every implementation entry also appears under api_boundary" do
      result =
        EffectiveBinding.expand_implications(%{
          "implementation" => ["Foo.bar/1", "Baz"]
        })

      assert result["implementation"] == ["Foo.bar/1", "Baz"]
      assert result["api_boundary"] == ["Baz", "Foo.bar/1"]
    end

    # covers: specled.realized_by.implication_one_way
    test "api_boundary-only entries do NOT seed implementation (one-way)" do
      result =
        EffectiveBinding.expand_implications(%{
          "api_boundary" => ["Only.api/0"]
        })

      assert result == %{"api_boundary" => ["Only.api/0"]}
      refute Map.has_key?(result, "implementation")
    end

    # covers: specled.realized_by.implication_invoked_per_layer
    test "is idempotent: calling twice produces the same result" do
      input = %{
        "implementation" => ["Foo.bar/1", "Foo.baz/2"],
        "api_boundary" => ["Foo.qux/3"]
      }

      once = EffectiveBinding.expand_implications(input)
      twice = EffectiveBinding.expand_implications(once)

      assert once == twice
    end

    # covers: specled.realized_by.implication_invoked_per_layer
    test "deduplicates api_boundary when subject already lists implementation entry there" do
      result =
        EffectiveBinding.expand_implications(%{
          "api_boundary" => ["Foo.bar/1"],
          "implementation" => ["Foo.bar/1"]
        })

      assert result["api_boundary"] == ["Foo.bar/1"]
      assert result["implementation"] == ["Foo.bar/1"]
    end

    # covers: specled.realized_by.implication_invoked_per_layer
    test "api_boundary list is sorted lexicographically" do
      result =
        EffectiveBinding.expand_implications(%{
          "implementation" => ["Zeta.z/0", "Alpha.a/0", "Mu.m/0"],
          "api_boundary" => ["Nu.n/0"]
        })

      assert result["api_boundary"] == [
               "Alpha.a/0",
               "Mu.m/0",
               "Nu.n/0",
               "Zeta.z/0"
             ]
    end

    test "empty input returns an empty map" do
      assert EffectiveBinding.expand_implications(%{}) == %{}
    end

    test "no implementation tier leaves api_boundary untouched (no sort, no dedup forced)" do
      input = %{"api_boundary" => ["Z.z/0", "A.a/0"]}

      assert EffectiveBinding.expand_implications(input) == input
    end

    test "no api_boundary tier yet but implementation present seeds api_boundary" do
      result =
        EffectiveBinding.expand_implications(%{
          "implementation" => ["B.b/1", "A.a/1"]
        })

      assert result["api_boundary"] == ["A.a/1", "B.b/1"]
      assert result["implementation"] == ["B.b/1", "A.a/1"]
    end

    test "tiers other than api_boundary and implementation are untouched" do
      result =
        EffectiveBinding.expand_implications(%{
          "implementation" => ["Foo.bar/1"],
          "expanded_behavior" => ["SomeBehaviour"],
          "use" => ["Some.Macro"],
          "typespecs" => ["Some.Type.t/0"]
        })

      assert result["expanded_behavior"] == ["SomeBehaviour"]
      assert result["use"] == ["Some.Macro"]
      assert result["typespecs"] == ["Some.Type.t/0"]
      assert result["implementation"] == ["Foo.bar/1"]
      assert result["api_boundary"] == ["Foo.bar/1"]
    end

    test "both tiers populated: api_boundary becomes the union, sorted and deduped" do
      result =
        EffectiveBinding.expand_implications(%{
          "api_boundary" => ["Z.z/0", "A.a/0"],
          "implementation" => ["A.a/0", "M.m/0"]
        })

      assert result["api_boundary"] == ["A.a/0", "M.m/0", "Z.z/0"]
      assert result["implementation"] == ["A.a/0", "M.m/0"]
    end

    test "atom tier keys are normalized to strings" do
      result =
        EffectiveBinding.expand_implications(%{
          implementation: ["Foo.bar/1"],
          api_boundary: ["Foo.qux/3"]
        })

      assert result["api_boundary"] == ["Foo.bar/1", "Foo.qux/3"]
      assert result["implementation"] == ["Foo.bar/1"]
    end

    test "bare-module entries flow through the implication identically to MFA strings" do
      result =
        EffectiveBinding.expand_implications(%{
          "implementation" => ["SpecLedEx.Coverage", "Foo.bar/1"]
        })

      assert result["api_boundary"] == ["Foo.bar/1", "SpecLedEx.Coverage"]
      assert result["implementation"] == ["SpecLedEx.Coverage", "Foo.bar/1"]
    end
  end
end
