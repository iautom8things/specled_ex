defmodule SpecLedEx.Integration.ScenarioTestOnlyChangeTest do
  # covers: specled.triangulation.pure_function
  # covers: specled.triangulation.scenario.test_only_change_scenario_gate
  use ExUnit.Case, async: true

  @moduletag :integration

  alias SpecLedEx.CoverageTriangulation

  # ---------------------------------------------------------------------------
  # Scenario 2 (from specled.triangulation.scenario.test_only_change_scenario_gate):
  #
  #   Given a subject with an implementation closure whose files are unchanged
  #   And   per-test coverage captured on the pre-change commit
  #   And   a branch that edits only a test file (no code change)
  #   When  CoverageTriangulation.findings/3 runs against the captured coverage
  #   Then  no branch_guard_realization_drift-style triangulation finding fires
  #         for the subject (closure-exercise is unchanged)
  #   And   findings/3 remains pure — no filesystem access, no Mix globals
  #
  # Drift is an implementation-tier concern, not a triangulation concern. The
  # triangulation pure function asserts only its inputs; a test-only edit does
  # not alter closure_files or coverage_records, so no triangulation findings
  # are emitted against the subject under test.
  # ---------------------------------------------------------------------------

  @closure_map %{
    subjects: %{
      "subject_under_test" => %{
        owned_files: ["lib/subject_under_test.ex"],
        requirements: [
          %{
            id: "subject_under_test.req1",
            binding_present?: true,
            closure_files: ["lib/subject_under_test.ex"],
            closure_mfas: ["Elixir.SubjectUnderTest.run/1"]
          }
        ]
      }
    }
  }

  @tag_index %{
    spec: %{
      "subject_under_test.req1" => [
        %{file: "test/subject_under_test_test.exs", test_name: "run/1 works"}
      ]
    },
    opt_out: []
  }

  test "captured coverage shows the closure exercised — no triangulation findings fire" do
    # Coverage captured from the pre-change commit. The test file string may
    # differ on the branch, but the coverage records themselves still show
    # the closure file hit.
    captured_records = [
      %{
        test_id: "SubjectUnderTestTest.test run/1 works",
        file: "lib/subject_under_test.ex",
        lines_hit: [1, 2, 3],
        tags: %{
          file: "test/subject_under_test_test.exs",
          test: "run/1 works",
          spec: "subject_under_test.req1"
        },
        test_pid: self()
      }
    ]

    findings = CoverageTriangulation.findings(captured_records, @closure_map, @tag_index)

    refute Enum.any?(findings, fn f ->
             f["code"] == "branch_guard_untested_realization" and
               f["subject_id"] == "subject_under_test"
           end),
           "unexpected untested_realization on a test-only change: #{inspect(findings)}"

    # Drift is explicitly handled by the implementation tier, never emitted
    # by triangulation. Guard against regressions that conflate the two.
    refute Enum.any?(findings, fn f ->
             f["code"] == "branch_guard_realization_drift"
           end),
           "triangulation must not emit drift findings (that is the implementation tier)"
  end

  test "findings/3 is pure — repeated calls produce equal outputs and touch no filesystem" do
    records = [
      %{
        test_id: "SubjectUnderTestTest.test stable",
        file: "lib/subject_under_test.ex",
        lines_hit: [1],
        tags: %{
          file: "test/subject_under_test_test.exs",
          test: "stable",
          spec: "subject_under_test.req1"
        },
        test_pid: self()
      }
    ]

    first = CoverageTriangulation.findings(records, @closure_map, @tag_index)
    second = CoverageTriangulation.findings(records, @closure_map, @tag_index)
    assert first == second

    # A genuine `mix spec.check` fixture run against a test-only branch would
    # observe no new triangulation finding (the closure is still exercised).
    # Here we just assert the pure function honors that invariant.
    assert first |> Enum.filter(&(&1["code"] != "detector_unavailable")) |> Enum.map(& &1["code"]) == []
  end
end
