defmodule SpecLedEx.Review.CoverageClosureTest.FixtureA do
  @moduledoc false
  def run(x), do: x
end

defmodule SpecLedEx.Review.CoverageClosureTest.FixtureB do
  @moduledoc false
  def run(x), do: x
end

defmodule SpecLedEx.Review.CoverageClosureTest.FixtureUnbound do
  @moduledoc false
end

defmodule SpecLedEx.Review.CoverageClosureTest do
  # covers: specled.triangulation.envelope_legacy_and_invalid_distinct
  # covers: specled.triangulation.envelope_aggregate_untested_realization
  # covers: specled.triangulation.envelope_per_test_only_detectors_unavailable
  # covers: specled.triangulation.envelope_aggregate_underspecified_realization
  # covers: specled.triangulation.aggregate_requirement_reach_mfa_intersection
  # covers: specled.spec_review.coverage_tab_v2_envelope_data_layer
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.triangulation.envelope_legacy_and_invalid_distinct",
               "specled.triangulation.envelope_aggregate_untested_realization",
               "specled.triangulation.envelope_per_test_only_detectors_unavailable",
               "specled.triangulation.envelope_aggregate_underspecified_realization",
               "specled.triangulation.aggregate_requirement_reach_mfa_intersection",
               "specled.spec_review.coverage_tab_v2_envelope_data_layer"
             ]

  alias SpecLedEx.Coverage.MfaKey
  alias SpecLedEx.Review.CoverageClosure
  alias SpecLedEx.Review.CoverageClosureTest.{FixtureA, FixtureB, FixtureUnbound}

  @fixture_a_mfa MfaKey.format({FixtureA, :run, 1})
  @fixture_b_mfa MfaKey.format({FixtureB, :run, 1})

  # A non-empty tracer_edges map is required to get past build_v2's
  # :no_tracer_manifest gate — Closure.compute/2 doesn't need real edges to
  # resolve top-level impl_bindings (only for transitive callee recursion),
  # so a stray self-entry is enough to exercise every other branch.
  @edges %{{FixtureA, :run, 1} => [], {FixtureB, :run, 1} => []}

  describe "build_v2/2 — status gating" do
    test "reports :no_tracer_manifest when the tracer manifest is missing, before checking coverage" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: %{},
          envelope: aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: true}])
        )

      assert reach["subject_a"] == %{status: :no_tracer_manifest, by_requirement: %{}}
    end

    test "reports :no_coverage_artifact distinctly, with an empty by_requirement map" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: :no_coverage_artifact
        )

      assert reach["subject_a"] == %{status: :no_coverage_artifact, by_requirement: %{}}
    end

    test "reports :legacy_artifact distinctly from :no_coverage_artifact and :invalid_artifact" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: :legacy_artifact
        )

      assert reach["subject_a"] == %{status: :legacy_artifact, by_requirement: %{}}
    end

    test "reports :invalid_artifact distinctly — never collapsed into an empty-but-ok result" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: :invalid_artifact
        )

      assert reach["subject_a"] == %{status: :invalid_artifact, by_requirement: %{}}
      assert reach["subject_a"].status != :ok_aggregate
      assert reach["subject_a"].status != :ok_per_test
    end

    test "reports :ok_aggregate for an :aggregate envelope and :ok_per_test for a :per_test envelope" do
      aggregate_reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: aggregate_envelope(mfas: [])
        )

      per_test_reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: []}
        )

      assert aggregate_reach["subject_a"].status == :ok_aggregate
      assert per_test_reach["subject_a"].status == :ok_per_test
    end

    # Flag 1 (specled_-155.7 orchestrator addendum): a degraded :per_test
    # envelope must never report as trustworthy :ok_per_test — the renderer
    # has no other channel to detect the async-contamination guard.
    test "reports :async_contaminated for a degraded :per_test envelope — never :ok_per_test, with an empty by_requirement map" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: [], degraded: true}
        )

      assert reach["subject_a"] == %{status: :async_contaminated, by_requirement: %{}}
      assert reach["subject_a"].status != :ok_per_test
    end

    test "a non-degraded :per_test envelope (degraded: false) still reports :ok_per_test with real data" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: [], degraded: false}
        )

      assert reach["subject_a"].status == :ok_per_test
    end
  end

  describe "build_v2/2 — aggregate mode MFA coverage" do
    test "would fail if it fell back to a lines_hit-style heuristic: closure_coverage_pct, covered/uncovered MFAs, and executed_mfa_count are computed straight from the envelope's per-MFA :covered flag" do
      envelope = aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: true}])

      reach = CoverageClosure.build_v2(fixture_index(), tracer_edges: @edges, envelope: envelope)
      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert req.closure_mfa_count == 1
      assert req.closure_coverage_pct == 100.0
      assert req.covered_mfas == [@fixture_a_mfa]
      assert req.uncovered_mfas == []
    end

    test "each subject's requirements are computed independently against the shared envelope" do
      envelope =
        aggregate_envelope(
          mfas: [
            %{mfa: @fixture_a_mfa, covered: true},
            %{mfa: @fixture_b_mfa, covered: false}
          ]
        )

      reach = CoverageClosure.build_v2(fixture_index(), tracer_edges: @edges, envelope: envelope)

      assert reach["subject_a"].by_requirement["subject_a.req1"].closure_coverage_pct == 100.0
      assert reach["subject_b"].by_requirement["subject_b.req1"].closure_coverage_pct == 0.0
    end

    test "closure_coverage_pct is a real 0.0 (not the zero-closure sentinel) when the closure exists but is uncovered" do
      envelope = aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: false}])

      reach = CoverageClosure.build_v2(fixture_index(), tracer_edges: @edges, envelope: envelope)
      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert req.closure_coverage_pct == 0.0
      assert req.uncovered_mfas == [@fixture_a_mfa]
    end

    test "'zero closure MFAs matched' is a distinct degraded status, not a silent 0% (silent-zero guard)" do
      index = fixture_index_with_unbound_subject()
      edges = %{{FixtureUnbound, :run, 1} => []}
      envelope = aggregate_envelope(mfas: [])

      reach = CoverageClosure.build_v2(index, tracer_edges: edges, envelope: envelope)
      req = reach["subject_unbound"].by_requirement["subject_unbound.req1"]

      # FixtureUnbound has no impl_binding at all, so its closure has zero
      # MFAs. closure_coverage_pct must be the distinct atom sentinel here,
      # never the float `0.0` that a genuinely-covered-but-untested closure
      # would report — collapsing the two would silently misreport "no
      # binding at all" as "0% coverage of a real closure".
      assert req.closure_mfa_count == 0
      assert req.closure_coverage_pct == :no_closure_mfas
      refute req.closure_coverage_pct == 0.0
    end
  end

  describe "build_v2/2 — tagged_tests evidence strength" do
    test "aggregate mode: a tagged test is \"linked\" when the closure has any execution, \"claimed\" when it has none" do
      linked_envelope = aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: true}])
      claimed_envelope = aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: false}])

      tag_index = %{
        spec: %{"subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}]},
        opt_out: []
      }

      linked_reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: linked_envelope,
          tag_index: tag_index
        )

      claimed_reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: claimed_envelope,
          tag_index: tag_index
        )

      assert [%{strength: "linked"}] =
               linked_reach["subject_a"].by_requirement["subject_a.req1"].tagged_tests

      assert [%{strength: "claimed"}] =
               claimed_reach["subject_a"].by_requirement["subject_a.req1"].tagged_tests
    end

    test "aggregate mode never reaches \"executed\" strength — self_verified? stays false (observed per-test attribution is possible only under :ok_per_test)" do
      envelope = aggregate_envelope(mfas: [%{mfa: @fixture_a_mfa, covered: true}])

      tag_index = %{
        spec: %{"subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}]},
        opt_out: []
      }

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: envelope,
          tag_index: tag_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      refute Enum.any?(req.tagged_tests, &(&1.strength == "executed"))
      refute req.self_verified?
    end

    test "per_test mode: a tagged test reaches \"executed\" when its own coverage record reaches the closure, and self_verified? composes closure coverage > 0 with an executed tagged test" do
      source = FixtureA.module_info(:compile)[:source] |> List.to_string()

      records = [
        %{
          test_id: "T.t1",
          file: source,
          lines_hit: [1],
          tags: %{file: "test/a_test.exs", test: "t1"},
          test_pid: self()
        }
      ]

      tag_index = %{
        spec: %{"subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}]},
        opt_out: []
      }

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: records},
          tag_index: tag_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert [%{strength: "executed"}] = req.tagged_tests
      assert req.closure_coverage_pct == 100.0
      assert req.self_verified?
    end

    test "per_test mode: a tagged test with no reaching coverage record is \"linked\", not \"executed\"" do
      tag_index = %{
        spec: %{"subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}]},
        opt_out: []
      }

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: []},
          tag_index: tag_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert [%{strength: "linked"}] = req.tagged_tests
      refute req.self_verified?
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp aggregate_envelope(mfas: mfas) do
    %{
      version: 2,
      mode: :aggregate,
      generated_at: ~U[2026-07-23 00:00:00Z],
      source: "test.coverdata",
      files: [],
      mfas: mfas,
      payload: %{unmapped_modules: 0},
      degraded: false
    }
  end

  defp fixture_index do
    %{
      "subjects" => [
        %{
          "meta" => %{
            "id" => "subject_a",
            "surface" => ["lib/fixture_a.ex"],
            "realized_by" => %{
              "implementation" => ["SpecLedEx.Review.CoverageClosureTest.FixtureA.run/1"]
            }
          },
          "requirements" => [%{"id" => "subject_a.req1"}]
        },
        %{
          "meta" => %{
            "id" => "subject_b",
            "surface" => ["lib/fixture_b.ex"],
            "realized_by" => %{
              "implementation" => ["SpecLedEx.Review.CoverageClosureTest.FixtureB.run/1"]
            }
          },
          "requirements" => [%{"id" => "subject_b.req1"}]
        }
      ]
    }
  end

  defp fixture_index_with_unbound_subject do
    %{
      "subjects" => [
        %{
          "meta" => %{
            "id" => "subject_unbound",
            "surface" => ["lib/fixture_unbound.ex"],
            "realized_by" => %{"implementation" => []}
          },
          "requirements" => [%{"id" => "subject_unbound.req1"}]
        }
      ]
    }
  end
end
