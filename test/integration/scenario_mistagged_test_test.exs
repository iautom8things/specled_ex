defmodule SpecLedEx.Integration.ScenarioMistaggedTestTest do
  # covers: specled.triangulation.untethered_test
  # covers: specled.triangulation.scenario.untethered_test_flagged
  # covers: specled.triangulation.scenario.opt_out_tag_suppresses
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.triangulation.untethered_test", "specled.triangulation.untethered_test_opt_out"]

  @moduletag :integration

  alias SpecLedEx.CoverageTriangulation

  # ---------------------------------------------------------------------------
  # Scenario 5 (from specled.triangulation.scenario.untethered_test_flagged +
  # specled.triangulation.scenario.opt_out_tag_suppresses):
  #
  #   Given a test tagged `@tag spec: "subject_a.req1"` that, according to
  #         captured per-test coverage, only exercises MFAs owned by subject_b
  #   When  CoverageTriangulation.findings/3 runs with the captured data
  #   Then  exactly one branch_guard_untethered_test finding is emitted, and
  #         its severity is :info (the default per the decision ADR)
  #   And   when the test additionally carries `@tag spec_triangulation:
  #         :indirect`, no untethered finding is emitted for that test.
  # ---------------------------------------------------------------------------

  @closure_map %{
    subjects: %{
      "subject_a" => %{
        owned_files: ["lib/subject_a.ex"],
        requirements: [
          %{
            id: "subject_a.req1",
            binding_present?: true,
            closure_files: ["lib/subject_a.ex"],
            closure_mfas: ["Elixir.SubjectA.run/1"]
          }
        ]
      },
      "subject_b" => %{
        owned_files: ["lib/subject_b.ex"],
        requirements: [
          %{
            id: "subject_b.req1",
            binding_present?: true,
            closure_files: ["lib/subject_b.ex"],
            closure_mfas: ["Elixir.SubjectB.run/1"]
          }
        ]
      }
    }
  }

  @tag_index %{
    spec: %{
      "subject_a.req1" => [%{file: "test/mistagged_test.exs", test_name: "mistagged"}],
      "subject_b.req1" => []
    },
    opt_out: []
  }

  defp mistagged_record(extra_tags \\ %{}) do
    base_tags = %{
      file: "test/mistagged_test.exs",
      test: "mistagged",
      spec: "subject_a.req1"
    }

    %{
      test_id: "MistaggedTest.test mistagged",
      file: "lib/subject_b.ex",
      lines_hit: [1, 2],
      tags: Map.merge(base_tags, extra_tags),
      test_pid: self()
    }
  end

  test "mistagged test yields exactly one untethered_test finding at :info severity" do
    findings = CoverageTriangulation.findings([mistagged_record()], @closure_map, @tag_index)

    untethered = Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test"))

    assert [finding] = untethered, "expected a single untethered finding, got: #{inspect(untethered)}"

    assert finding["severity"] == "info"
    assert finding["subject_id"] == "subject_a"
    assert finding["tag"] == "subject_a.req1"
    assert finding["observed_owners"] == ["subject_b"]
    assert finding["file"] == "test/mistagged_test.exs"
  end

  test "adding @tag spec_triangulation: :indirect on the test suppresses the untethered finding" do
    findings =
      CoverageTriangulation.findings(
        [mistagged_record(%{spec_triangulation: :indirect})],
        @closure_map,
        @tag_index
      )

    assert Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test")) == []
  end

  test "adding the test to tag_index.opt_out suppresses the untethered finding" do
    opt_out_index = %{
      @tag_index
      | opt_out: [%{file: "test/mistagged_test.exs", test_name: "mistagged"}]
    }

    findings = CoverageTriangulation.findings([mistagged_record()], @closure_map, opt_out_index)
    assert Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test")) == []
  end
end
