defmodule SpecLedEx.Integration.ScenarioTestOnlyChangeTest do
  # covers: specled.triangulation.pure_function
  # covers: specled.triangulation.scenario.test_only_change_scenario_gate
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.triangulation.pure_function"]

  @moduletag :integration

  alias SpecLedEx.CoverageTriangulation

  # ---------------------------------------------------------------------------
  # Transcribed verbatim from specled.triangulation.scenario.test_only_change_scenario_gate
  # in .spec/specs/triangulation.spec.md. Keep the two in sync — a paraphrase
  # here that drifts from the spec block is the defect class specled_-cz0 exists
  # to remove.
  #
  #   Given a subject whose requirement declares a present binding with one
  #         closure file and one closure MFA
  #   And   per-test coverage records captured before the change, showing that
  #         closure file exercised
  #   And   a branch that edits only the covering test file, leaving the closure
  #         unchanged
  #   When  `CoverageTriangulation.findings/3` is called with those captured
  #         records, the closure map, and the tag index — `mix spec.check` never
  #         runs triangulation and is not a consumer of this detector
  #         (Decision 1, `specled.decision.aggregate_first_spec_coverage`)
  #   Then  no `branch_guard_untested_realization` finding references the subject
  #         (the closure is still exercised)
  #   And   no `branch_guard_realization_drift` finding is emitted at all — drift
  #         is an implementation-tier concern that triangulation never reports
  #
  # The scenario has no purity `then:` clause. The no-filesystem/no-processes
  # half of specled.triangulation.pure_function is proven by tracing in
  # test/specled_ex/coverage_triangulation_test.exs:43, not here; this file
  # covers the requirement's test-only-change behavior and determinism.
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

  test "findings/3 is deterministic — repeated calls produce equal outputs" do
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

    # A `mix spec.triangle` / `mix spec.review` run against a test-only branch
    # would observe no new triangulation finding (the closure is still
    # exercised); `mix spec.check` never runs triangulation at all. Assert that
    # literally: NO finding, not "no finding other than detector_unavailable".
    # detector_unavailable is itself a triangulation finding, so filtering it
    # out would let a spurious one fire against a fully-exercised closure.
    assert first == []
  end
end
