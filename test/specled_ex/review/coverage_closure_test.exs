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
  # covers: specled.triangulation.per_test_requirement_reach
  # covers: specled.spec_review.coverage_tab_v2_envelope_data_layer
  # async-safety: build_v2's closure-file normalization reads the VM-global
  # cwd (File.cwd!/0). Safe here because the only File.cd!/1 in the suite
  # lives in an async: false module (realization/binding_test.exs), and
  # ExUnit never overlaps async and sync modules.
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.triangulation.envelope_legacy_and_invalid_distinct",
               "specled.triangulation.envelope_aggregate_untested_realization",
               "specled.triangulation.envelope_per_test_only_detectors_unavailable",
               "specled.triangulation.envelope_aggregate_underspecified_realization",
               "specled.triangulation.aggregate_requirement_reach_mfa_intersection",
               "specled.triangulation.per_test_requirement_reach",
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
    test "per_test reach is computed once with the full multi-subject closure map" do
      source = FixtureA.module_info(:compile)[:source] |> List.to_string()

      line_index = %{
        FixtureA => %{{:run, 1} => MapSet.new([10])},
        FixtureB => %{{:run, 1} => MapSet.new([20])}
      }

      records = [
        %{
          test_id: "T.a",
          file: source,
          lines_hit: [10],
          tags: %{file: "test/a_test.exs", test: "a"},
          test_pid: self()
        },
        %{
          test_id: "T.b",
          file: source,
          lines_hit: [20],
          tags: %{file: "test/b_test.exs", test: "b"},
          test_pid: self()
        }
      ]

      parent = self()

      per_test_reach_fn = fn payload, closure_map, index ->
        send(parent, {:per_test_reach, payload, closure_map, index})

        SpecLedEx.CoverageTriangulation.per_test_requirement_reach(
          payload,
          closure_map,
          index
        )
      end

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: records, degraded: false, meta: %{}},
          line_index: line_index,
          per_test_reach_fn: per_test_reach_fn
        )

      assert_receive {:per_test_reach, ^records, closure_map, ^line_index}
      assert closure_map.subjects |> Map.keys() |> Enum.sort() == ["subject_a", "subject_b"]
      refute_receive {:per_test_reach, _records, _closure_map, _line_index}

      assert reach["subject_a"].by_requirement["subject_a.req1"].covered_mfas == [
               @fixture_a_mfa
             ]

      assert reach["subject_b"].by_requirement["subject_b.req1"].covered_mfas == [
               @fixture_b_mfa
             ]
    end

    # covers: specled.triangulation.v1_file_level_path_identity
    @tag spec: ["specled.triangulation.v1_file_level_path_identity"]
    test "closure_files in the reach closure map join repo-relative record files through the v1 file-level reach" do
      parent = self()

      per_test_reach_fn = fn payload, closure_map, index ->
        send(parent, {:closure_map, closure_map})
        SpecLedEx.CoverageTriangulation.per_test_requirement_reach(payload, closure_map, index)
      end

      CoverageClosure.build_v2(fixture_index(),
        tracer_edges: @edges,
        envelope: %{mode: :per_test, payload: [], degraded: false},
        line_index: %{},
        per_test_reach_fn: per_test_reach_fn
      )

      assert_receive {:closure_map, closure_map}
      [req] = closure_map.subjects["subject_a"].requirements

      # FixtureA's compile source is this file's absolute path; the closure
      # map must carry it repo-root-relative or file-level joins against
      # repo-relative record files can never match.
      assert req.closure_files == ["test/specled_ex/review/coverage_closure_test.exs"]
      assert req.binding_present?

      # Drive the SHOULD-match case through the v1 file-level consumer of
      # this closure map: a repo-relative record must reach the closure file.
      records = [
        %{
          test_id: "T.t1",
          file: "test/specled_ex/review/coverage_closure_test.exs",
          lines_hit: [3],
          tags: %{file: "test/a_test.exs", test: "t1"},
          test_pid: self()
        }
      ]

      reach = SpecLedEx.CoverageTriangulation.per_requirement_reach(records, closure_map)
      entry = reach[{"subject_a", "subject_a.req1"}]

      assert entry.reached_files == ["test/specled_ex/review/coverage_closure_test.exs"]
      assert entry.unreached_files == []
      assert entry.reaching_tests == ["test/a_test.exs :: t1"]
    end

    # covers: specled.triangulation.v1_file_level_path_identity
    @tag spec: ["specled.triangulation.v1_file_level_path_identity"]
    test "an out-of-repo compile source contributes no closure file but keeps binding_present? from its closure MFAs" do
      parent = self()

      per_test_reach_fn = fn payload, closure_map, index ->
        send(parent, {:closure_map, closure_map})
        SpecLedEx.CoverageTriangulation.per_test_requirement_reach(payload, closure_map, index)
      end

      CoverageClosure.build_v2(fixture_index_with_external_binding(),
        tracer_edges: %{{Enum, :map, 2} => []},
        envelope: %{mode: :per_test, payload: [], degraded: false},
        line_index: %{},
        per_test_reach_fn: per_test_reach_fn
      )

      assert_receive {:closure_map, closure_map}
      [req] = closure_map.subjects["subject_ext"].requirements

      # Enum compiles outside any consuming repository, so no repo-relative
      # identity exists for it — the closure carries no file rather than an
      # absolute path no record can equal. The binding itself must not
      # collapse: the MFA-level untested-realization gate reads
      # binding_present? and must keep flagging this requirement.
      assert req.closure_files == []
      assert req.closure_mfas == ["Enum.map/2"]
      assert req.binding_present?
    end

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

    test "per_test mode: a tagged test reaches \"executed\" when its own coverage record intersects the MFA line set, and self_verified? composes closure coverage > 0 with an executed tagged test" do
      source = FixtureA.module_info(:compile)[:source] |> List.to_string()
      # Would fail if CoverageClosure still used the file-level proxy (any
      # lines_hit on the MFA's source file): hitting a non-MFA line must not
      # mark FixtureA.run/1 covered. Real line→MFA intersection requires the
      # hit to fall inside the MFA's line set from the stub index.
      line_index = %{
        FixtureA => %{{:run, 1} => MapSet.new([10, 11, 12])},
        FixtureB => %{{:run, 1} => MapSet.new([20])}
      }

      records = [
        %{
          test_id: "T.t1",
          file: source,
          lines_hit: [11],
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
          envelope: %{mode: :per_test, payload: records, degraded: false, meta: %{}},
          tag_index: tag_index,
          line_index: line_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert reach["subject_a"].status == :ok_per_test
      assert reach["subject_a"].attribution == :exact
      assert [%{strength: "executed"}] = req.tagged_tests
      assert req.closure_coverage_pct == 100.0
      assert req.covered_mfas == [@fixture_a_mfa]
      assert req.self_verified?
    end

    test "per_test mode: a hit on the MFA's source file outside the MFA line set does not cover the MFA (would fail if file-level proxy returned)" do
      source = FixtureA.module_info(:compile)[:source] |> List.to_string()

      line_index = %{
        FixtureA => %{{:run, 1} => MapSet.new([10, 11, 12])},
        FixtureB => %{{:run, 1} => MapSet.new([20])}
      }

      records = [
        %{
          test_id: "T.t1",
          file: source,
          # Line 99 is in FixtureA's source file but not in run/1's line set.
          lines_hit: [99],
          tags: %{file: "test/a_test.exs", test: "t1"},
          test_pid: self()
        }
      ]

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: records, degraded: false, meta: %{}},
          line_index: line_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert req.covered_mfas == []
      assert req.uncovered_mfas == [@fixture_a_mfa]
      assert req.closure_coverage_pct == 0.0
    end

    test "per_test mode: a tagged test with no reaching coverage record is \"linked\", not \"executed\"" do
      tag_index = %{
        spec: %{"subject_a.req1" => [%{file: "test/a_test.exs", test_name: "t1"}]},
        opt_out: []
      }

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: [], degraded: false, meta: %{}},
          tag_index: tag_index,
          line_index: %{
            FixtureA => %{{:run, 1} => MapSet.new([10])},
            FixtureB => %{{:run, 1} => MapSet.new([20])}
          }
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert [%{strength: "linked"}] = req.tagged_tests
      refute req.self_verified?
    end

    test "per_test mode: :no_debug_info modules surface as no_debug_info_mfas, not covered or uncovered" do
      line_index = %{
        FixtureA => :no_debug_info,
        FixtureB => %{{:run, 1} => MapSet.new([20])}
      }

      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: [], degraded: false, meta: %{}},
          line_index: line_index
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert req.no_debug_info_mfas == [@fixture_a_mfa]
      assert req.unresolvable_source_mfas == []
      assert req.covered_mfas == []
      assert req.uncovered_mfas == []
      # closure_mfa_count still counts the MFA; executed is 0 because nothing
      # was provably covered — pct is a real 0.0, not the zero-closure sentinel.
      assert req.closure_mfa_count == 1
      assert req.closure_coverage_pct == 0.0
    end

    @tag spec: [
           "specled.triangulation.per_test_unresolvable_source_partition",
           "specled.spec_review.coverage_tab_v2_envelope_data_layer"
         ]
    test "per_test mode: CoverageClosure preserves unresolvable MFAs in the percentage denominator" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{mode: :per_test, payload: [], degraded: false, meta: %{}},
          line_index: %{FixtureB => %{{:run, 1} => MapSet.new([20])}}
        )

      req = reach["subject_a"].by_requirement["subject_a.req1"]

      assert req.unresolvable_source_mfas == [@fixture_a_mfa]
      assert req.no_debug_info_mfas == []
      assert req.covered_mfas == []
      assert req.uncovered_mfas == []
      assert req.closure_mfa_count == 1
      assert req.closure_coverage_pct == 0.0
    end

    @tag spec: "specled.triangulation.per_test_path_identity"
    test "per_test mode: repo-relative record paths join an absolute compile source path" do
      source =
        FixtureA.module_info(:compile)[:source]
        |> List.to_string()
        |> Path.relative_to_cwd()

      records = [
        %{
          test_id: "T.relative",
          file: source,
          lines_hit: [17],
          tags: %{file: "test/relative_test.exs", test: "relative"}
        }
      ]

      req =
        single_requirement_reach(
          @fixture_a_mfa,
          records,
          %{FixtureA => %{{:run, 1} => MapSet.new([17])}}
        )

      assert req.covered_mfas == [@fixture_a_mfa]
      assert req.reaching_tests == ["test/relative_test.exs :: relative"]
      assert req.unresolvable_source_mfas == []
    end

    @tag spec: "specled.triangulation.per_test_unresolvable_source_partition"
    test "per_test mode: a closure module absent from the line index is unresolvable, not no-debug or uncovered" do
      req = single_requirement_reach(@fixture_a_mfa, [], %{})

      assert req.unresolvable_source_mfas == [@fixture_a_mfa]
      assert req.no_debug_info_mfas == []
      assert req.uncovered_mfas == []
      assert req.closure_mfa_count == 1
      assert req.executed_mfa_count == 0
    end

    @tag spec: "specled.triangulation.per_test_unresolvable_source_partition"
    test "per_test mode: an MFA absent from an otherwise present function index is unresolvable" do
      req =
        single_requirement_reach(
          @fixture_a_mfa,
          [],
          %{FixtureA => %{{:other, 0} => MapSet.new([1])}}
        )

      assert req.unresolvable_source_mfas == [@fixture_a_mfa]
      assert req.no_debug_info_mfas == []
      assert req.uncovered_mfas == []
    end

    @tag spec: "specled.triangulation.per_test_unresolvable_source_partition"
    test "per_test mode: a module whose compile source cannot resolve is unresolvable" do
      module = UnloadableIdentityModule
      mfa = MfaKey.format({module, :run, 1})

      req =
        single_requirement_reach(
          mfa,
          [],
          %{module => %{{:run, 1} => MapSet.new([1])}}
        )

      assert req.unresolvable_source_mfas == [mfa]
      assert req.no_debug_info_mfas == []
      assert req.uncovered_mfas == []
    end

    @tag spec: "specled.triangulation.per_test_unresolvable_source_partition"
    test "per_test mode: an unparseable closure MFA is unresolvable rather than uncovered" do
      req = single_requirement_reach("not-an-mfa", [], %{})

      assert req.unresolvable_source_mfas == ["not-an-mfa"]
      assert req.no_debug_info_mfas == []
      assert req.uncovered_mfas == []
    end

    test "per_test mode: unhooked-degraded envelope stays :ok_per_test with attribution :degraded_unhooked (not :async_contaminated)" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{
            mode: :per_test,
            payload: [],
            degraded: true,
            meta: %{unhooked_modules: [UnhookedTestModule]}
          },
          line_index: %{
            FixtureA => %{{:run, 1} => MapSet.new([10])},
            FixtureB => %{{:run, 1} => MapSet.new([20])}
          }
        )

      assert reach["subject_a"].status == :ok_per_test
      assert reach["subject_a"].attribution == :degraded_unhooked
      assert reach["subject_a"].unhooked_modules == [UnhookedTestModule]
      refute reach["subject_a"].status == :async_contaminated
    end

    @tag spec: "specled.spec_review.coverage_async_dominates_unhooked"
    test "per_test mode: async dominates unhooked — an overlap degrade reports :async_contaminated, never :ok_per_test" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{
            mode: :per_test,
            payload: [],
            degraded: true,
            meta: %{
              unhooked_modules: [UnhookedTestModule],
              degraded_reasons: [:async, :unhooked]
            }
          }
        )

      # Pre-degraded_reasons, non-empty unhooked meta masked the async
      # contamination and re-published corrupted windows as trustworthy.
      assert reach["subject_a"] == %{status: :async_contaminated, by_requirement: %{}}
    end

    @tag spec: "specled.spec_review.coverage_async_dominates_unhooked"
    test "per_test mode: harvest-only degrade (degraded_reasons [:counters_harvested]) also refuses :ok_per_test" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{
            mode: :per_test,
            payload: [],
            degraded: true,
            meta: %{degraded_reasons: [:counters_harvested]}
          }
        )

      assert reach["subject_a"] == %{status: :async_contaminated, by_requirement: %{}}
    end

    @tag spec: "specled.spec_review.coverage_async_dominates_unhooked"
    test "per_test mode: explicit unhooked-only degraded_reasons stays :ok_per_test with attribution :degraded_unhooked" do
      reach =
        CoverageClosure.build_v2(fixture_index(),
          tracer_edges: @edges,
          envelope: %{
            mode: :per_test,
            payload: [],
            degraded: true,
            meta: %{
              unhooked_modules: [UnhookedTestModule],
              degraded_reasons: [:unhooked]
            }
          },
          line_index: %{
            FixtureA => %{{:run, 1} => MapSet.new([10])},
            FixtureB => %{{:run, 1} => MapSet.new([20])}
          }
        )

      assert reach["subject_a"].status == :ok_per_test
      assert reach["subject_a"].attribution == :degraded_unhooked
    end
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp single_requirement_reach(mfa, records, line_index) do
    closure_map = %{
      subjects: %{
        "subject" => %{
          requirements: [%{id: "subject.requirement", closure_mfas: [mfa]}]
        }
      }
    }

    records
    |> SpecLedEx.CoverageTriangulation.per_test_requirement_reach(closure_map, line_index)
    |> Map.fetch!({"subject", "subject.requirement"})
  end

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

  defp fixture_index_with_external_binding do
    %{
      "subjects" => [
        %{
          "meta" => %{
            "id" => "subject_ext",
            "surface" => ["lib/fixture_ext.ex"],
            "realized_by" => %{"implementation" => ["Enum.map/2"]}
          },
          "requirements" => [%{"id" => "subject_ext.req1"}]
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
