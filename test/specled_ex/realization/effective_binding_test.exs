defmodule SpecLedEx.Realization.EffectiveBindingTest do
  use ExUnit.Case, async: true
  @moduletag spec: [
                "specled.realized_by.effective_binding_inherits_subject",
                "specled.realized_by.effective_binding_requirement_replaces_tier",
                "specled.realized_by.effective_binding_accepts_subject_shape"
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
end
