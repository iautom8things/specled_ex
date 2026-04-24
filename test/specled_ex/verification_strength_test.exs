defmodule SpecLedEx.VerificationStrengthTest do
  use ExUnit.Case
  @moduletag spec: ["specled.verify.command_execution_resilience", "specled.verify.command_exit_code_recorded", "specled.verify.command_output_via_tempfile", "specled.verify.command_timeout_enforced", "specled.verify.coverage_warnings", "specled.verify.decision_governance", "specled.verify.malformed_entries_nonfatal", "specled.verify.meta_required", "specled.verify.reference_checks", "specled.verify.strength_semantics", "specled.verify.target_existence"]

  alias SpecLedEx.VerificationStrength

  test "levels and default remain stable" do
    assert VerificationStrength.levels() == ~w(claimed linked executed)
    assert VerificationStrength.default() == "claimed"
    assert VerificationStrength.valid?("linked")
    refute VerificationStrength.valid?("strongest")
  end

  test "normalize and compare enforce the proof ordering" do
    assert VerificationStrength.normalize("executed") == {:ok, "executed"}
    assert VerificationStrength.normalize(nil) == {:ok, nil}
    assert {:error, message} = VerificationStrength.normalize("strongest")
    assert message =~ "claimed, linked, executed"

    assert VerificationStrength.compare("claimed", "linked") == :lt
    assert VerificationStrength.compare("linked", "claimed") == :gt
    assert VerificationStrength.compare("executed", "executed") == :eq

    assert VerificationStrength.meets_minimum?("executed", "linked")
    assert VerificationStrength.meets_minimum?("linked", "linked")
    refute VerificationStrength.meets_minimum?("claimed", "linked")
  end
end
