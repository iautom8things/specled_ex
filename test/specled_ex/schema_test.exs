defmodule SpecLedEx.SchemaTest do
  use SpecLedEx.Case

  alias SpecLedEx.Schema
  alias SpecLedEx.Schema.{Exception, Meta, Requirement, Scenario, Verification}

  test "validate_block accepts valid spec-meta as a Zoi-backed struct" do
    assert {:ok, meta} =
             Schema.validate_block("spec-meta", %{
               "id" => "example.subject",
               "kind" => "module",
               "status" => "active",
               "summary" => "preserved",
               "decisions" => ["repo.policy"],
               "verification_minimum_strength" => "linked"
             })

    assert %Meta{} = meta
    assert meta.summary == "preserved"
    assert meta.decisions == ["repo.policy"]
    assert meta.verification_minimum_strength == "linked"
    assert Schema.meta() == Meta.schema()
  end

  for {tag, item, module, assertion} <- [
        {"spec-requirements", %{"id" => "example.requirement", "statement" => "Requirement"},
         Requirement, {:id, "example.requirement"}},
        {"spec-scenarios",
         %{
           "id" => "example.scenario",
           "covers" => ["example.requirement"],
           "given" => ["given"],
           "when" => ["when"],
           "then" => ["then"]
         }, Scenario, {:id, "example.scenario"}},
        {"spec-verification",
         %{
           "kind" => "source_file",
           "target" => "lib/example.ex",
           "covers" => ["example.requirement"]
         }, Verification, {:target, "lib/example.ex"}},
        {"spec-exceptions",
         %{
           "id" => "example.exception",
           "covers" => ["example.requirement"],
           "reason" => "accepted"
         }, Exception, {:reason, "accepted"}}
      ] do
    @schema_tag tag
    @schema_item item
    @schema_module module
    @schema_assertion assertion

    test "#{tag} accepts valid list items as structs" do
      assert {:ok, [validated]} = Schema.validate_block(@schema_tag, [@schema_item])
      {field, expected} = @schema_assertion
      assert validated.__struct__ == @schema_module
      assert Map.fetch!(validated, field) == expected
    end
  end

  test "validate_block rejects invalid meta identifiers" do
    assert {:error, message} =
             Schema.validate_block("spec-meta", %{
               "id" => "Bad Subject",
               "kind" => "module",
               "status" => "active"
             })

    assert message =~ "spec-meta validation failed"
    assert message =~ "invalid id format"
  end

  test "validate_block rejects invalid verification minimum strength" do
    assert {:error, message} =
             Schema.validate_block("spec-meta", %{
               "id" => "example.subject",
               "kind" => "module",
               "status" => "active",
               "verification_minimum_strength" => "strongest"
             })

    assert message =~ "spec-meta validation failed"
  end

  test "validate_block reports item indexes for invalid list entries" do
    assert {:error, message} =
             Schema.validate_block("spec-requirements", [
               %{"statement" => "Missing id"}
             ])

    assert message =~ "spec-requirements[0] validation failed"
  end

  test "validate_block rejects unknown verification kinds" do
    assert {:error, message} =
             Schema.validate_block("spec-verification", [
               %{
                 "kind" => "typo_kind",
                 "target" => "ignored",
                 "covers" => ["example.requirement"]
               }
             ])

    assert message =~ "spec-verification[0] validation failed"
  end

  describe "decision schema change_type" do
    alias SpecLedEx.Schema.Decision

    test "accepts every value in the change_type enum" do
      for change_type <- Decision.change_types() do
        decision =
          Zoi.parse(Decision.schema(), %{
            "id" => "adr.example",
            "status" => "accepted",
            "date" => "2026-04-23",
            "affects" => ["example.subject"],
            "change_type" => change_type
          })

        assert {:ok, result} = decision
        assert result.change_type == change_type
      end
    end

    test "rejects change_type values outside the enum" do
      assert {:error, _} =
               Zoi.parse(Decision.schema(), %{
                 "id" => "adr.example",
                 "status" => "accepted",
                 "date" => "2026-04-23",
                 "affects" => ["example.subject"],
                 "change_type" => "not-a-real-change-type"
               })
    end

    test "accepts the deprecated status" do
      assert {:ok, result} =
               Zoi.parse(Decision.schema(), %{
                 "id" => "adr.example",
                 "status" => "deprecated",
                 "date" => "2026-04-23",
                 "affects" => ["example.subject"]
               })

      assert result.status == "deprecated"
    end

    test "accepts replaces and reverses_what optional fields" do
      assert {:ok, result} =
               Zoi.parse(Decision.schema(), %{
                 "id" => "adr.new",
                 "status" => "accepted",
                 "date" => "2026-04-23",
                 "affects" => ["example.subject"],
                 "change_type" => "supersedes",
                 "replaces" => ["adr.old"],
                 "reverses_what" => "old decision is obsolete"
               })

      assert result.replaces == ["adr.old"]
      assert result.reverses_what == "old decision is obsolete"
    end

    test "weakening_types/0 returns exactly four atoms" do
      assert Decision.weakening_types() ==
               ~w(deprecates weakens narrows-scope adds-exception)
    end
  end

  describe "requirement schema optional fields" do
    test "accepts polarity, refines, and supersedes" do
      assert {:ok, [req]} =
               Schema.validate_block("spec-requirements", [
                 %{
                   "id" => "example.req_a",
                   "statement" => "The system SHALL do X.",
                   "polarity" => "negative",
                   "refines" => "example.req_parent",
                   "supersedes" => "example.req_old"
                 }
               ])

      assert req.polarity == "negative"
      assert req.refines == "example.req_parent"
      assert req.supersedes == "example.req_old"
    end

    test "rejects polarity values outside the enum" do
      assert {:error, _message} =
               Schema.validate_block("spec-requirements", [
                 %{
                   "id" => "example.req_a",
                   "statement" => "Statement",
                   "polarity" => "indifferent"
                 }
               ])
    end

    test "existing fixtures without the new fields still parse" do
      assert {:ok, [req]} =
               Schema.validate_block("spec-requirements", [
                 %{"id" => "example.req", "statement" => "Statement"}
               ])

      assert req.polarity == nil
      assert req.refines == nil
      assert req.supersedes == nil
    end
  end

  describe "scenario schema execute and reason" do
    test "accepts execute and reason optional fields" do
      assert {:ok, [scenario]} =
               Schema.validate_block("spec-scenarios", [
                 %{
                   "id" => "example.scenario",
                   "covers" => ["example.req"],
                   "given" => ["given"],
                   "when" => ["when"],
                   "then" => ["then"],
                   "execute" => false,
                   "reason" => "disabled pending refactor"
                 }
               ])

      assert scenario.execute == false
      assert scenario.reason == "disabled pending refactor"
    end

    test "existing scenarios without execute/reason still parse" do
      assert {:ok, [scenario]} =
               Schema.validate_block("spec-scenarios", [
                 %{
                   "id" => "example.scenario",
                   "covers" => ["example.req"],
                   "given" => ["g"],
                   "when" => ["w"],
                   "then" => ["t"]
                 }
               ])

      assert scenario.execute == nil
      assert scenario.reason == nil
    end
  end
end
