defmodule SpecLedEx.Config.BranchGuardTest do
  use SpecLedEx.Case

  alias SpecLedEx.Config
  alias SpecLedEx.Config.BranchGuard

  describe "parse/1" do
    @tag spec: "specled.severity.resolve_precedence"
    test "accepts known severity tokens per code" do
      {%BranchGuard{severities: severities}, []} =
        BranchGuard.parse(%{
          "severities" => %{
            "branch_guard_realization_drift" => "info",
            "spec_requirement_too_short" => "off"
          }
        })

      assert severities == %{
               "branch_guard_realization_drift" => :info,
               "spec_requirement_too_short" => :off
             }
    end

    @tag spec: "specled.severity.known_values"
    test "drops unknown severity tokens with diagnostic" do
      {%BranchGuard{severities: severities}, diagnostics} =
        BranchGuard.parse(%{"severities" => %{"some_code" => "panic"}})

      assert severities == %{}
      assert Enum.any?(diagnostics, &String.contains?(&1, "some_code"))
      assert Enum.any?(diagnostics, &String.contains?(&1, "panic"))
    end

    @tag spec: "specled.severity.resolve_precedence"
    test "missing severities key returns empty" do
      assert {%BranchGuard{severities: %{}}, []} = BranchGuard.parse(%{})
    end
  end

  describe "Config.load/2 integrates BranchGuard" do
    @tag spec: "specled.severity.resolve_precedence"
    test "loads severity overrides from YAML", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join([root, ".spec", "config.yml"]), """
      branch_guard:
        severities:
          spec_requirement_too_short: off
      """)

      config = Config.load(root)
      assert config.branch_guard.severities == %{"spec_requirement_too_short" => :off}
      assert config.diagnostics == []
    end

    @tag spec: "specled.severity.known_values"
    test "records a diagnostic when severity is unknown", %{root: root} do
      File.mkdir_p!(Path.join(root, ".spec"))

      File.write!(Path.join([root, ".spec", "config.yml"]), """
      branch_guard:
        severities:
          some_code: panic
      """)

      config = Config.load(root)
      assert config.branch_guard.severities == %{}
      assert Enum.any?(config.diagnostics, &(&1.message =~ "panic"))
    end
  end
end
