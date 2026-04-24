defmodule SpecLedEx.Realization.EffectiveBindingTest do
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.realized_by.effective_binding_inherits_subject", "specled.realized_by.effective_binding_requirement_replaces_tier"]

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
  end
end
