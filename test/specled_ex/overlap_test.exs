defmodule SpecLedEx.OverlapTest do
  # covers: specled.overlap.duplicate_covers specled.overlap.must_stem_collision specled.overlap.within_subject_scope specled.overlap.findings_sorted specled.overlap.no_prior_state
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.overlap.duplicate_covers", "specled.overlap.findings_sorted", "specled.overlap.must_stem_collision", "specled.overlap.no_prior_state", "specled.overlap.within_subject_scope"]

  alias SpecLedEx.Overlap

  defp subject(id, scenarios) do
    %{
      "id" => id,
      "file" => ".spec/specs/#{id}.spec.md",
      "meta" => %{"id" => id, "kind" => "module", "status" => "active"},
      "scenarios" => scenarios
    }
  end

  defp scenario(id, covers) do
    %{"id" => id, "covers" => covers}
  end

  defp requirement(id, statement, subject_id, priority \\ "must") do
    %{
      "id" => id,
      "statement" => statement,
      "subject_id" => subject_id,
      "priority" => priority
    }
  end

  describe "duplicate_covers" do
    @tag spec: "specled.overlap.duplicate_covers"
    test "two scenarios in the same subject both listing the same requirement id emit :error" do
      subjects = [
        subject("x", [
          scenario("x.scenario.a", ["x.req_1"]),
          scenario("x.scenario.b", ["x.req_1"])
        ])
      ]

      assert [finding] = Overlap.analyze(subjects, [])
      assert finding.code == "overlap/duplicate_covers"
      assert finding.severity == :error
      assert finding.subject_id == "x"
      assert finding.entity_id == "x.req_1"
      assert finding.message =~ "x.scenario.a"
      assert finding.message =~ "x.scenario.b"
      assert finding.message =~ "x.req_1"
      assert finding.message =~ "fix:"
    end

    test "three scenarios on the same requirement collapse into one finding naming all three" do
      subjects = [
        subject("x", [
          scenario("x.scenario.a", ["x.req_1"]),
          scenario("x.scenario.b", ["x.req_1"]),
          scenario("x.scenario.c", ["x.req_1"])
        ])
      ]

      assert [finding] = Overlap.analyze(subjects, [])
      assert finding.message =~ "x.scenario.a"
      assert finding.message =~ "x.scenario.b"
      assert finding.message =~ "x.scenario.c"
    end

    test "disjoint scenarios inside a subject produce no finding" do
      subjects = [
        subject("x", [
          scenario("x.scenario.a", ["x.req_1"]),
          scenario("x.scenario.b", ["x.req_2"])
        ])
      ]

      assert [] == Overlap.analyze(subjects, [])
    end
  end

  describe "must_stem_collision" do
    @tag spec: "specled.overlap.must_stem_collision"
    test "two MUST requirements with the same statement in the same subject emit :error" do
      requirements = [
        requirement("x.req_1", "The system MUST reject invalid input.", "x"),
        requirement("x.req_2", "The system MUST reject invalid input.", "x")
      ]

      assert [finding] = Overlap.analyze([], requirements)
      assert finding.code == "overlap/must_stem_collision"
      assert finding.severity == :error
      assert finding.subject_id == "x"
      assert finding.message =~ "x.req_1"
      assert finding.message =~ "x.req_2"
      assert finding.message =~ "fix:"
    end

    test "trailing punctuation and case differences do not escape detection" do
      requirements = [
        requirement("x.req_1", "The system MUST reject invalid input.", "x"),
        requirement("x.req_2", "The SYSTEM must reject invalid input", "x")
      ]

      assert [finding] = Overlap.analyze([], requirements)
      assert finding.code == "overlap/must_stem_collision"
    end

    test "non-MUST requirements do not participate" do
      requirements = [
        requirement("x.req_1", "The system should reject invalid input.", "x", "should"),
        requirement("x.req_2", "The system should reject invalid input.", "x", "should")
      ]

      assert [] == Overlap.analyze([], requirements)
    end

    test "differing MUST statements do not collide" do
      requirements = [
        requirement("x.req_1", "The system MUST reject invalid input.", "x"),
        requirement("x.req_2", "The system MUST log every auth attempt.", "x")
      ]

      assert [] == Overlap.analyze([], requirements)
    end
  end

  describe "within-subject scope" do
    @tag spec: "specled.overlap.within_subject_scope"
    test "cross-subject duplicate covers are ignored" do
      subjects = [
        subject("x", [scenario("x.scenario.a", ["shared.req"])]),
        subject("y", [scenario("y.scenario.b", ["shared.req"])])
      ]

      assert [] == Overlap.analyze(subjects, [])
    end

    test "cross-subject MUST-stem duplicates are ignored" do
      requirements = [
        requirement("x.req_1", "The system MUST reject invalid input.", "x"),
        requirement("y.req_1", "The system MUST reject invalid input.", "y")
      ]

      assert [] == Overlap.analyze([], requirements)
    end
  end

  describe "findings_sorted" do
    @tag spec: "specled.overlap.findings_sorted"
    test "findings are sorted by {subject_id, entity_id, code}" do
      subjects = [
        subject("b", [
          scenario("b.scenario.a", ["b.req_1"]),
          scenario("b.scenario.b", ["b.req_1"])
        ]),
        subject("a", [
          scenario("a.scenario.a", ["a.req_1"]),
          scenario("a.scenario.b", ["a.req_1"])
        ])
      ]

      requirements = [
        requirement("a.req_9", "The system MUST frobnicate.", "a"),
        requirement("a.req_8", "The system MUST frobnicate.", "a")
      ]

      findings = Overlap.analyze(subjects, requirements)

      keys =
        Enum.map(findings, fn f ->
          {f.subject_id || "", f.entity_id || "", f.code || ""}
        end)

      assert keys == Enum.sort(keys)
      assert Enum.map(findings, & &1.subject_id) == Enum.sort(Enum.map(findings, & &1.subject_id))
    end
  end

  describe "pure head-only" do
    @tag spec: "specled.overlap.no_prior_state"
    test "identical head inputs return equal findings lists" do
      subjects = [
        subject("x", [
          scenario("x.scenario.a", ["x.req_1"]),
          scenario("x.scenario.b", ["x.req_1"])
        ])
      ]

      requirements = [
        requirement("x.req_2", "The system MUST foo.", "x"),
        requirement("x.req_3", "The system MUST foo.", "x")
      ]

      assert Overlap.analyze(subjects, requirements) ==
               Overlap.analyze(subjects, requirements)
    end

    test "empty inputs return []" do
      assert [] == Overlap.analyze([], [])
    end
  end
end
