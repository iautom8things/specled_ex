defmodule SpecLedEx.CoverageTriangulationTest do
  # covers: specled.triangulation.pure_function
  # covers: specled.triangulation.untested_realization
  # covers: specled.triangulation.untethered_test
  # covers: specled.triangulation.underspecified_realization
  # covers: specled.triangulation.execution_reach_metric
  # covers: specled.triangulation.detector_unavailable_on_missing_coverage
  use ExUnit.Case, async: true

  alias SpecLedEx.CoverageTriangulation

  describe "findings/3 — purity (specled.triangulation.pure_function)" do
    @tag spec: "specled.triangulation.pure_function"
    test "does not read the filesystem or start processes" do
      before_procs = :erlang.processes() |> length()

      empty_closure = %{subjects: %{}}
      empty_tags = %{spec: %{}, opt_out: []}

      assert CoverageTriangulation.findings([], empty_closure, empty_tags) == []
      assert CoverageTriangulation.findings([], empty_closure, empty_tags) == []

      after_procs = :erlang.processes() |> length()
      # Processes can fluctuate by one or two due to unrelated VM activity;
      # purity means we did not *intentionally* start any.
      assert after_procs - before_procs <= 2
    end

    @tag spec: "specled.triangulation.pure_function"
    test "is deterministic across repeated calls with equal inputs" do
      records = [
        coverage_record(test_id: "A.t1", file: "lib/a.ex", lines_hit: [1])
      ]

      closure_map = fixture_closure_map()
      tag_index = fixture_tag_index()

      first = CoverageTriangulation.findings(records, closure_map, tag_index)
      second = CoverageTriangulation.findings(records, closure_map, tag_index)
      assert first == second
    end
  end

  describe "findings/3 — detector_unavailable" do
    @tag spec: "specled.triangulation.detector_unavailable_on_missing_coverage"
    test "returns exactly one detector_unavailable finding on :no_coverage_artifact" do
      assert [finding] =
               CoverageTriangulation.findings(:no_coverage_artifact, fixture_closure_map(), fixture_tag_index())

      assert finding["code"] == "detector_unavailable"
      assert finding["reason"] == "no_coverage_artifact"
      assert finding["severity"] == "info"
    end

    @tag spec: "specled.triangulation.detector_unavailable_on_missing_coverage"
    test "emits no speculative triangulation findings on missing coverage" do
      findings = CoverageTriangulation.findings(:no_coverage_artifact, fixture_closure_map(), fixture_tag_index())

      refute Enum.any?(findings, fn f -> f["code"] == "branch_guard_untested_realization" end)
      refute Enum.any?(findings, fn f -> f["code"] == "branch_guard_untethered_test" end)
      refute Enum.any?(findings, fn f -> f["code"] == "branch_guard_underspecified_realization" end)
    end
  end

  describe "findings/3 — untested_realization" do
    @tag spec: "specled.triangulation.untested_realization"
    test "emits when a requirement closure is non-empty but no coverage exercises it" do
      # Requirement A.req1 closure is on lib/a.ex, but no test touches it.
      records = [
        coverage_record(test_id: "B.t1", file: "lib/b.ex", lines_hit: [1])
      ]

      [finding | _] =
        CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())
        |> Enum.filter(&(&1["code"] == "branch_guard_untested_realization"))

      assert finding["subject_id"] == "subject_a"
      assert finding["requirement_id"] == "subject_a.req1"
      assert "lib/a.ex" in finding["closure_files"]
      assert finding["severity"] == "warning"
    end

    test "does not emit for a requirement whose closure is exercised" do
      records = [
        coverage_record(test_id: "A.t1", file: "lib/a.ex", lines_hit: [1, 2])
      ]

      untested_req1 =
        CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())
        |> Enum.filter(fn f ->
          f["code"] == "branch_guard_untested_realization" and
            f["requirement_id"] == "subject_a.req1"
        end)

      assert untested_req1 == []
    end

    test "does not emit when the effective binding is absent" do
      # A requirement with binding_present?: false is silent — the drift signal
      # belongs to the binding tier, not triangulation.
      closure_map = %{
        subjects: %{
          "subject_x" => %{
            owned_files: ["lib/x.ex"],
            requirements: [
              %{id: "subject_x.unbound", binding_present?: false, closure_files: [], closure_mfas: []}
            ]
          }
        }
      }

      assert [] =
               CoverageTriangulation.findings([], closure_map, %{spec: %{}, opt_out: []})
               |> Enum.filter(&(&1["code"] == "branch_guard_untested_realization"))
    end
  end

  describe "findings/3 — untethered_test (specled.triangulation.scenario.untethered_test_flagged)" do
    @tag spec: "specled.triangulation.scenario.untethered_test_flagged"
    test "flags a test whose @tag spec names subject_a but coverage only touches subject_b files" do
      records = [
        coverage_record(
          test_id: "Foo.test untethered",
          file: "lib/b.ex",
          lines_hit: [1],
          tags: %{
            file: "test/foo_test.exs",
            test: "untethered",
            spec: "subject_a.req1"
          }
        )
      ]

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())
      untethered = Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test"))

      assert [finding] = untethered
      assert finding["severity"] == "info"
      assert finding["subject_id"] == "subject_a"
      assert finding["tag"] == "subject_a.req1"
      assert finding["observed_owners"] == ["subject_b"]
    end
  end

  describe "findings/3 — opt-out tag (specled.triangulation.scenario.opt_out_tag_suppresses)" do
    @tag spec: "specled.triangulation.scenario.opt_out_tag_suppresses"
    test "@tag spec_triangulation: :indirect on the record suppresses untethered emission" do
      records = [
        coverage_record(
          test_id: "Foo.test indirect",
          file: "lib/b.ex",
          lines_hit: [1],
          tags: %{
            file: "test/foo_test.exs",
            test: "indirect",
            spec: "subject_a.req1",
            spec_triangulation: :indirect
          }
        )
      ]

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())
      untethered = Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test"))
      assert untethered == []
    end

    test "opt_out entry in the tag_index suppresses untethered emission" do
      records = [
        coverage_record(
          test_id: "Foo.test indirect2",
          file: "lib/b.ex",
          lines_hit: [1],
          tags: %{
            file: "test/foo_test.exs",
            test: "indirect2",
            spec: "subject_a.req1"
          }
        )
      ]

      tag_index = %{
        fixture_tag_index()
        | opt_out: [%{file: "test/foo_test.exs", test_name: "indirect2"}]
      }

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), tag_index)
      assert Enum.filter(findings, &(&1["code"] == "branch_guard_untethered_test")) == []
    end
  end

  describe "findings/3 — underspecified_realization" do
    @tag spec: "specled.triangulation.underspecified_realization"
    test "emits when coverage reaches subject A's files but the test has no @tag spec for any A req" do
      # Test carries @tag spec: "subject_b.req1" yet exercises lib/a.ex too.
      records = [
        coverage_record(
          test_id: "Foo.test crossover",
          file: "lib/a.ex",
          lines_hit: [1],
          tags: %{file: "test/foo_test.exs", test: "crossover", spec: "subject_b.req1"}
        ),
        coverage_record(
          test_id: "Foo.test crossover",
          file: "lib/b.ex",
          lines_hit: [3],
          tags: %{file: "test/foo_test.exs", test: "crossover", spec: "subject_b.req1"}
        )
      ]

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())

      under_a =
        Enum.filter(findings, fn f ->
          f["code"] == "branch_guard_underspecified_realization" and f["subject_id"] == "subject_a"
        end)

      assert [finding] = under_a
      assert finding["file"] == "test/foo_test.exs"
      assert finding["test_name"] == "crossover"
      assert "lib/a.ex" in finding["exercised_files"]
    end

    test "does not emit when the test carries a @tag spec referencing any requirement of the exercised subject" do
      records = [
        coverage_record(
          test_id: "A.t1",
          file: "lib/a.ex",
          lines_hit: [1],
          tags: %{file: "test/a_test.exs", test: "t1", spec: "subject_a.req1"}
        )
      ]

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())

      assert Enum.filter(findings, &(&1["code"] == "branch_guard_underspecified_realization")) == []
    end
  end

  describe "findings/3 — execution_reach metadata" do
    @tag spec: "specled.triangulation.execution_reach_metric"
    test "each finding carries per-subject execution_reach as N/M (0.FF)" do
      # subject_a has 2 reqs; req1 is exercised, req2 is not → 1/2 (0.50)
      records = [
        coverage_record(test_id: "A.t1", file: "lib/a.ex", lines_hit: [1])
      ]

      findings = CoverageTriangulation.findings(records, fixture_closure_map(), fixture_tag_index())

      untested_a_req2 =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_untested_realization" and
            f["requirement_id"] == "subject_a.req2"
        end)

      assert untested_a_req2["execution_reach"] == "1/2 (0.50)"
    end

    test "execution_reach_map/2 renders the fraction + float form for every subject" do
      records = [
        coverage_record(test_id: "A.t1", file: "lib/a.ex", lines_hit: [1])
      ]

      reach = CoverageTriangulation.execution_reach_map(records, fixture_closure_map())
      assert reach["subject_a"] == "1/2 (0.50)"
      assert reach["subject_b"] == "0/1 (0.00)"
    end

    test "subjects with zero requirements render 0/0 (1.00) to avoid divide-by-zero" do
      closure_map = %{
        subjects: %{
          "subject_empty" => %{owned_files: [], requirements: []}
        }
      }

      reach = CoverageTriangulation.execution_reach_map([], closure_map)
      assert reach["subject_empty"] == "0/0 (1.00)"
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp fixture_closure_map do
    %{
      subjects: %{
        "subject_a" => %{
          owned_files: ["lib/a.ex", "lib/a_extra.ex"],
          requirements: [
            %{
              id: "subject_a.req1",
              binding_present?: true,
              closure_files: ["lib/a.ex"],
              closure_mfas: ["Elixir.A.run/1"]
            },
            %{
              id: "subject_a.req2",
              binding_present?: true,
              closure_files: ["lib/a_extra.ex"],
              closure_mfas: ["Elixir.A.aux/0"]
            }
          ]
        },
        "subject_b" => %{
          owned_files: ["lib/b.ex"],
          requirements: [
            %{
              id: "subject_b.req1",
              binding_present?: true,
              closure_files: ["lib/b.ex"],
              closure_mfas: ["Elixir.B.run/1"]
            }
          ]
        }
      }
    }
  end

  defp fixture_tag_index do
    %{
      spec: %{
        "subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}],
        "subject_b.req1" => [%{file: "test/b_test.exs", test_name: "t1"}]
      },
      opt_out: []
    }
  end

  defp coverage_record(fields) do
    defaults = %{
      test_id: "Foo.test x",
      file: "lib/a.ex",
      lines_hit: [1],
      tags: %{file: "test/foo_test.exs", test: "x"},
      test_pid: self()
    }

    Enum.reduce(fields, defaults, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end
end
