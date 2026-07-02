defmodule SpecLedEx.Config.RealizationTest do
  use SpecLedEx.Case, async: true

  @moduletag spec: "specled.config.realization_enabled_tiers"

  alias SpecLedEx.Config.Realization

  describe "parse/1" do
    test "parses a valid enabled_tiers list in order and dedupes repeated tiers" do
      {realization, diagnostics} =
        Realization.parse(%{
          "enabled_tiers" => [
            "api_boundary",
            "implementation",
            "implementation",
            :expanded_behavior,
            "use",
            "typespecs"
          ]
        })

      assert realization == %Realization{
               enabled_tiers: [
                 :api_boundary,
                 :implementation,
                 :expanded_behavior,
                 :use,
                 :typespecs
               ],
               rejected: []
             }

      assert diagnostics == []
    end

    test "accepts atom keys for enabled_tiers" do
      {realization, diagnostics} =
        Realization.parse(%{enabled_tiers: [:api_boundary, "implementation"]})

      assert realization.enabled_tiers == [:api_boundary, :implementation]
      assert realization.rejected == []
      assert diagnostics == []
    end

    test "records unknown names on rejected and returns diagnostics" do
      {realization, diagnostics} =
        Realization.parse(%{
          "enabled_tiers" => ["api_boundary", "shenanigans", 42, :unknown]
        })

      assert realization.enabled_tiers == [:api_boundary]
      assert realization.rejected == ["shenanigans", 42, :unknown]

      assert diagnostics == [
               "realization.enabled_tiers rejected: \"shenanigans\"",
               "realization.enabled_tiers rejected: 42",
               "realization.enabled_tiers rejected: :unknown"
             ]
    end

    test "keeps absent enabled_tiers as nil" do
      {realization, diagnostics} = Realization.parse(%{})

      assert realization == Realization.defaults()
      assert realization.enabled_tiers == nil
      assert diagnostics == []
    end

    test "returns defaults for non-map input" do
      assert Realization.parse(["api_boundary"]) == {Realization.defaults(), []}
    end

    test "preserves an explicit empty list" do
      {realization, diagnostics} = Realization.parse(%{"enabled_tiers" => []})

      assert realization.enabled_tiers == []
      assert realization.rejected == []
      assert diagnostics == []
    end
  end
end
