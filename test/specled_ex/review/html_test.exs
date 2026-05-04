defmodule SpecLedEx.Review.HtmlTest do
  # Triangle leg classifier + sync checklist tests.
  #
  # The leg classifier (render_sync_diagram) and the sync checklist
  # (build_sync_checks) translate finding codes into per-leg statuses.
  # These tests pin the triangle vocabulary documented in
  # docs/concepts.md to the diagram + checklist legs they belong to,
  # so a fixture-style triage carrying any one of those codes flips the
  # correct row from green to amber.

  use ExUnit.Case, async: true

  alias SpecLedEx.Review.Html

  defp triage(findings_by_code, overrides \\ %{}) do
    Map.merge(
      %{
        affected_subject_count: 1,
        requirement_count: 2,
        binding_count: 3,
        verification_count: 1,
        adr_ref_count: 0,
        strength_breakdown: %{},
        findings_by_code: findings_by_code,
        detector_unavailable_by_leg: %{}
      },
      overrides
    )
  end

  defp checks_by_codes(checks) do
    Enum.reduce(checks, %{}, fn check, acc ->
      Enum.reduce(check.codes, acc, fn code, inner ->
        Map.update(inner, code, [check], &[check | &1])
      end)
    end)
  end

  # Pull the labels of edges in a given state. The diagram renders each
  # edge as `<div class="sync-edge sync-edge-<state>" ...>...<span ...>icon</span>
  # <label></div>`. We need the label text to verify which side flipped.
  defp extract_labels(html, state) do
    pattern = ~r|sync-edge sync-edge-#{state}.*?sync-edge-icon">[^<]*</span>\s*([^<]+)</div>|s

    Regex.scan(pattern, html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.trim/1)
  end

  describe "render_sync_diagram leg classifier — SPEC ↔ CODE" do
    for code <- ~w(branch_guard_realization_drift branch_guard_dangling_binding) do
      @code code
      test "#{@code} flips the realized_by edge from ok to fail" do
        clean = triage(%{})
        dirty = triage(%{@code => 1})

        assert "realized_by" in extract_labels(
                 IO.iodata_to_binary(Html.render_sync_diagram(clean)),
                 "ok"
               )

        assert "realized_by" in extract_labels(
                 IO.iodata_to_binary(Html.render_sync_diagram(dirty)),
                 "fail"
               )
      end
    end
  end

  describe "render_sync_diagram leg classifier — SPEC ↔ TESTS" do
    for code <- ~w(
          branch_guard_untested_realization
          requirement_without_test_tag
          branch_guard_requirement_without_test_tag
        ) do
      @code code
      test "#{@code} flips the @tag spec edge from ok to fail" do
        dirty = triage(%{@code => 1})

        # The "@tag spec" edge is the diagram's Code → Tests edge by
        # position; in the triangle vocabulary it represents SPEC ↔ TESTS.
        assert "@tag spec" in extract_labels(
                 IO.iodata_to_binary(Html.render_sync_diagram(dirty)),
                 "fail"
               )
      end
    end
  end

  describe "render_sync_diagram leg classifier — CODE ↔ TESTS" do
    for code <- ~w(branch_guard_untethered_test branch_guard_underspecified_realization) do
      @code code
      test "#{@code} flips the evidence edge from ok to fail" do
        dirty = triage(%{@code => 1}, %{strength_breakdown: %{executed: 1}})

        assert "evidence" in extract_labels(
                 IO.iodata_to_binary(Html.render_sync_diagram(dirty)),
                 "fail"
               )
      end
    end
  end

  describe "build_sync_checks — Spec well-formed row" do
    test "overlap/duplicate_covers fails the 'spec files are well-formed' check" do
      checks = Html.build_sync_checks(triage(%{"overlap/duplicate_covers" => 1}))
      spec_check = Enum.find(checks, &(&1.label == "The spec files themselves are well-formed"))

      assert spec_check
      assert spec_check.passed? == false
      assert "overlap/duplicate_covers" in spec_check.codes
    end

    test "overlap/must_stem_collision fails the 'spec files are well-formed' check" do
      checks =
        Html.build_sync_checks(triage(%{"overlap/must_stem_collision" => 1}))

      spec_check = Enum.find(checks, &(&1.label == "The spec files themselves are well-formed"))

      assert spec_check
      assert spec_check.passed? == false
      assert "overlap/must_stem_collision" in spec_check.codes
    end
  end

  describe "build_sync_checks — Decisions / governance row" do
    @append_only_codes ~w(
      append_only/requirement_deleted
      append_only/must_downgraded
      append_only/scenario_regression
      append_only/negative_removed
      append_only/disabled_without_reason
      append_only/no_baseline
      append_only/adr_affects_widened
      append_only/same_pr_self_authorization
      append_only/missing_change_type
      append_only/decision_deleted
    )

    test "the row exists with leg label 'Decisions / governance'" do
      checks = Html.build_sync_checks(triage(%{}))
      gov = Enum.find(checks, &(&1.leg == "Decisions / governance"))

      assert gov, "expected a 'Decisions / governance' row to exist"
    end

    test "the row covers every append_only/* code in the catalog" do
      checks = Html.build_sync_checks(triage(%{}))
      gov = Enum.find(checks, &(&1.leg == "Decisions / governance"))

      for code <- @append_only_codes do
        assert code in gov.codes,
               "Decisions / governance row missing append_only code: #{code}"
      end
    end

    for code <- ~w(
          append_only/requirement_deleted
          append_only/must_downgraded
          append_only/scenario_regression
          append_only/negative_removed
          append_only/disabled_without_reason
          append_only/no_baseline
          append_only/adr_affects_widened
          append_only/same_pr_self_authorization
          append_only/missing_change_type
          append_only/decision_deleted
        ) do
      @code code
      test "#{@code} flips the 'Decisions / governance' row from passed to failed" do
        clean = Html.build_sync_checks(triage(%{}))
        dirty = Html.build_sync_checks(triage(%{@code => 1}))

        clean_gov = Enum.find(clean, &(&1.leg == "Decisions / governance"))
        dirty_gov = Enum.find(dirty, &(&1.leg == "Decisions / governance"))

        assert clean_gov.passed? == true
        assert dirty_gov.passed? == false
        assert dirty_gov.count == 1
      end
    end
  end

  describe "build_sync_checks — Spec → Code triangle row" do
    for code <- ~w(branch_guard_realization_drift branch_guard_dangling_binding) do
      @code code
      test "#{@code} fails the realized_by-binding integrity check" do
        checks = Html.build_sync_checks(triage(%{@code => 1}))

        binding_check =
          Enum.find(checks, fn c ->
            c.leg == "Spec → Code" and c.codes == ~w(branch_guard_realization_drift branch_guard_dangling_binding)
          end)

        assert binding_check, "expected a Spec → Code row covering the realization-drift codes"
        assert binding_check.passed? == false
      end
    end
  end

  describe "build_sync_checks — Spec → Tests triangle rows" do
    test "branch_guard_untested_realization fails the 'binding closure exercised' row" do
      checks = Html.build_sync_checks(triage(%{"branch_guard_untested_realization" => 1}))

      row =
        Enum.find(checks, fn c ->
          c.leg == "Spec → Tests" and "branch_guard_untested_realization" in c.codes
        end)

      assert row
      assert row.passed? == false
    end

    for code <- ~w(requirement_without_test_tag branch_guard_requirement_without_test_tag) do
      @code code
      test "#{@code} fails the 'must under tagged_tests has @tag spec:' row" do
        checks = Html.build_sync_checks(triage(%{@code => 1}))

        row =
          Enum.find(checks, fn c ->
            c.leg == "Spec → Tests" and @code in c.codes
          end)

        assert row
        assert row.passed? == false
      end
    end
  end

  describe "build_sync_checks — Code → Tests triangle row" do
    for code <- ~w(branch_guard_untethered_test branch_guard_underspecified_realization) do
      @code code
      test "#{@code} fails the 'tagged tests exercise the subject they claim' row" do
        checks = Html.build_sync_checks(triage(%{@code => 1}))

        row =
          Enum.find(checks, fn c ->
            c.leg == "Code → Tests" and @code in c.codes
          end)

        assert row, "expected a Code → Tests row covering #{@code}"
        assert row.passed? == false
      end
    end
  end

  describe "leg coverage parity with concepts.md vocabulary" do
    # This is a meta-check: every triangle code documented in concepts.md
    # is wired to at least one diagram leg or checklist row. If the spec
    # gains a new code class, this test should fail until the classifier
    # is updated.
    @diagram_triangle_codes ~w(
      branch_guard_realization_drift
      branch_guard_dangling_binding
      branch_guard_untested_realization
      branch_guard_untethered_test
      branch_guard_underspecified_realization
      requirement_without_test_tag
      branch_guard_requirement_without_test_tag
    )

    # overlap/* are within-spec consistency findings. They surface in the
    # "Spec files are well-formed" checklist row but do not change the
    # triangle's diagram edges (they're upstream of the triangle itself).
    @checklist_only_codes ~w(overlap/duplicate_covers overlap/must_stem_collision)

    test "every documented triangle code is covered by at least one checklist row" do
      checks = Html.build_sync_checks(triage(%{}))
      lookup = checks_by_codes(checks)

      for code <- @diagram_triangle_codes ++ @checklist_only_codes do
        assert Map.has_key?(lookup, code),
               "triangle code #{code} is not wired into any sync-check row"
      end
    end

    test "every triangle code that has a diagram-edge mapping flips an edge to fail" do
      for code <- @diagram_triangle_codes do
        labels_fail =
          IO.iodata_to_binary(Html.render_sync_diagram(triage(%{code => 1})))
          |> extract_labels("fail")

        assert labels_fail != [],
               "triangle code #{code} did not flip any diagram edge to fail"
      end
    end

    test "checklist-only codes do not flip diagram edges (they're upstream of the triangle)" do
      for code <- @checklist_only_codes do
        labels_fail =
          IO.iodata_to_binary(Html.render_sync_diagram(triage(%{code => 1})))
          |> extract_labels("fail")

        assert labels_fail == [],
               "checklist-only code #{code} unexpectedly flipped a diagram edge"
      end
    end
  end

  describe "render_sync_diagram leg classifier — :degraded for detector_unavailable" do
    # covers: specled.spec_review.degraded_leg_state
    test "no_coverage_artifact flips the evidence edge to degraded" do
      degraded =
        triage(%{}, %{
          detector_unavailable_by_leg: %{tests_to_coverage: %{"no_coverage_artifact" => 1}}
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(degraded))

      assert "evidence" in extract_labels(html, "degraded"),
             "no_coverage_artifact should flip the evidence edge to :degraded"

      refute "evidence" in extract_labels(html, "ok")
      refute "evidence" in extract_labels(html, "fail")
    end

    test "debug_info_stripped flips the realized_by edge to degraded" do
      degraded =
        triage(%{}, %{
          detector_unavailable_by_leg: %{spec_to_code: %{"debug_info_stripped" => 1}}
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(degraded))

      assert "realized_by" in extract_labels(html, "degraded")
      refute "realized_by" in extract_labels(html, "ok")
    end

    test "umbrella_unsupported flips the realized_by edge to degraded" do
      degraded =
        triage(%{}, %{
          detector_unavailable_by_leg: %{spec_to_code: %{"umbrella_unsupported" => 1}}
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(degraded))

      assert "realized_by" in extract_labels(html, "degraded")
    end

    test "a fail finding on the same leg supersedes a degraded reason" do
      both =
        triage(%{"branch_guard_realization_drift" => 1}, %{
          detector_unavailable_by_leg: %{spec_to_code: %{"debug_info_stripped" => 1}}
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(both))

      assert "realized_by" in extract_labels(html, "fail"),
             "a real failure must outrank a detector_unavailable on the same leg"

      refute "realized_by" in extract_labels(html, "degraded")
    end

    test "the degraded edge renders with a ? glyph (not ✓ or ✗)" do
      degraded =
        triage(%{}, %{
          detector_unavailable_by_leg: %{tests_to_coverage: %{"no_coverage_artifact" => 1}}
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(degraded))

      assert html =~ ~s|sync-edge sync-edge-degraded|

      # Pull the icon span out of the degraded edge specifically.
      assert Regex.match?(
               ~r|sync-edge sync-edge-degraded.*?sync-edge-icon">\?</span>|s,
               html
             ),
             "the degraded edge should render its glyph as ? (not ✓ or ✗)"
    end

    test "the degraded edge tooltip names every distinct reason on that leg" do
      degraded =
        triage(%{}, %{
          detector_unavailable_by_leg: %{
            spec_to_code: %{"debug_info_stripped" => 2, "umbrella_unsupported" => 1}
          }
        })

      html = IO.iodata_to_binary(Html.render_sync_diagram(degraded))

      [tooltip] =
        Regex.run(
          ~r|sync-edge sync-edge-degraded[^>]*title="([^"]+)"|,
          html,
          capture: :all_but_first
        )

      assert tooltip =~ "debug_info_stripped"
      assert tooltip =~ "umbrella_unsupported"
    end
  end

  describe "render_degraded_banner" do
    # covers: specled.spec_review.degraded_leg_state
    test "renders a banner when any leg carries a detector_unavailable finding" do
      banner =
        Html.render_degraded_banner(
          triage(%{}, %{
            detector_unavailable_by_leg: %{
              tests_to_coverage: %{"no_coverage_artifact" => 1}
            }
          })
        )

      assert banner =~ ~s|class="sync-degraded-banner"|
      assert banner =~ "no_coverage_artifact"
      assert banner =~ "Partial report"
    end

    test "renders an empty string when no detector_unavailable findings exist" do
      banner = Html.render_degraded_banner(triage(%{}))

      assert banner == ""
    end

    test "the banner enumerates every distinct reason across legs" do
      banner =
        Html.render_degraded_banner(
          triage(%{}, %{
            detector_unavailable_by_leg: %{
              spec_to_code: %{"debug_info_stripped" => 2, "umbrella_unsupported" => 1},
              tests_to_coverage: %{"no_coverage_artifact" => 1}
            }
          })
        )

      assert banner =~ "debug_info_stripped"
      assert banner =~ "umbrella_unsupported"
      assert banner =~ "no_coverage_artifact"
    end
  end

  describe "build_sync_checks — degraded rows" do
    # covers: specled.spec_review.degraded_leg_state
    test "a tests_to_coverage detector_unavailable marks tests/coverage rows as degraded" do
      checks =
        Html.build_sync_checks(
          triage(%{}, %{
            detector_unavailable_by_leg: %{tests_to_coverage: %{"no_coverage_artifact" => 1}}
          })
        )

      coverage_check = Enum.find(checks, &(&1.leg == "Coverage"))

      assert coverage_check
      assert coverage_check.passed? == true
      assert Map.get(coverage_check, :degraded?) == true
      assert Map.get(coverage_check, :degraded_reasons) == %{"no_coverage_artifact" => 1}
    end

    test "rows on legs with no detector_unavailable are not marked degraded" do
      checks =
        Html.build_sync_checks(
          triage(%{}, %{
            detector_unavailable_by_leg: %{tests_to_coverage: %{"no_coverage_artifact" => 1}}
          })
        )

      spec_well_formed = Enum.find(checks, &(&1.leg == "Spec"))

      assert spec_well_formed
      refute Map.get(spec_well_formed, :degraded?, false)
    end

    test "a failing finding on a degraded leg keeps the row failing, not degraded" do
      checks =
        Html.build_sync_checks(
          triage(%{"branch_guard_realization_drift" => 1}, %{
            detector_unavailable_by_leg: %{spec_to_code: %{"debug_info_stripped" => 1}}
          })
        )

      drift_row =
        Enum.find(checks, fn c ->
          "branch_guard_realization_drift" in c.codes
        end)

      assert drift_row
      assert drift_row.passed? == false
      # degraded? requires passed? — when a real failure exists, the row
      # is fail, not degraded.
      refute Map.get(drift_row, :degraded?, false)
    end
  end

  # covers: specled.spec_review.decisions_governance_inline
  describe "render_decisions_changed — append_only governance findings" do
    defp finding(code, opts \\ []) do
      %{
        "code" => code,
        "severity" => Keyword.get(opts, :severity, "error"),
        "subject_id" => Keyword.get(opts, :subject_id, "x"),
        "entity_id" => Keyword.get(opts, :entity_id, "x.req_a"),
        "message" =>
          Keyword.get(
            opts,
            :message,
            """
            Requirement `x.req_a` was present at base and is absent at head.

            ```
            fix: author an ADR with change_type in {deprecates, weakens, narrows-scope, adds-exception} and affects: [x.req_a] — or restore the requirement in its spec file.
            ```
            """
          )
      }
    end

    test "with no decisions and no findings, the panel still renders the empty message" do
      html = IO.iodata_to_binary(Html.render_decisions_changed([], %{}, []))

      assert html =~ "Decisions changed (0)"
      assert html =~ "No ADR files changed"
      refute html =~ "Governance violations"
    end

    test "an unauthorized requirement deletion surfaces in a Governance violations subsection even when no ADR file changed" do
      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed([], %{}, [finding("append_only/requirement_deleted")])
        )

      assert html =~ "Governance violations"
      assert html =~ "append_only/requirement_deleted"

      assert html =~
               "Requirement `x.req_a` was present at base and is absent at head"

      assert html =~ "governance-finding-fix"

      assert html =~
               "fix: author an ADR with change_type in {deprecates, weakens, narrows-scope, adds-exception}"
    end

    test "the rendered finding preserves the code-fenced fix block emitted by AppendOnly.analyze" do
      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed([], %{}, [finding("append_only/requirement_deleted")])
        )

      # The fix block lives inside <pre class="governance-finding-fix"><code>...</code></pre>
      # and is the verbatim text that the finding generator wrote.
      assert html =~ ~r|<pre class="governance-finding-fix"><code>fix:[^<]+</code></pre>|s
    end

    test "an append_only/* finding whose entity_id matches a present ADR renders inline under that ADR card" do
      decision = %{
        id: "specled.decision.adr_x",
        file: ".spec/decisions/adr_x.md",
        status: "accepted",
        change_type: "weakens",
        affects: ["x.req_a"]
      }

      adr = %{
        id: "specled.decision.adr_x",
        file: ".spec/decisions/adr_x.md",
        title: "ADR X",
        status: "accepted",
        date: nil,
        change_type: "weakens",
        affects: ["x.req_a"],
        body_text: "body",
        change_status: :modified
      }

      finding =
        finding("append_only/adr_affects_widened",
          entity_id: "specled.decision.adr_x",
          message:
            "ADR `specled.decision.adr_x` was status: accepted at base but its structural fields changed at head.\n\n```\nfix: revert the field edit on the accepted ADR.\n```\n"
        )

      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed(
            [decision],
            %{"specled.decision.adr_x" => adr},
            [finding]
          )
        )

      assert html =~ "Decisions changed (1)"
      assert html =~ "Governance findings naming this ADR"
      assert html =~ "append_only/adr_affects_widened"
      # Inline rendering means the orphan subsection is NOT used for this one
      refute html =~ "Governance violations (1)"
    end

    test "mixed: an inline-mapped finding and an orphan finding render in their respective places" do
      decision = %{
        id: "specled.decision.adr_x",
        file: ".spec/decisions/adr_x.md",
        status: "accepted",
        change_type: "weakens",
        affects: ["x.req_a"]
      }

      adr = %{
        id: "specled.decision.adr_x",
        file: ".spec/decisions/adr_x.md",
        title: "ADR X",
        status: "accepted",
        date: nil,
        change_type: "weakens",
        affects: ["x.req_a"],
        body_text: "body",
        change_status: :modified
      }

      inline =
        finding("append_only/adr_affects_widened",
          entity_id: "specled.decision.adr_x",
          message: "ADR widened.\n\n```\nfix: revert.\n```\n"
        )

      orphan = finding("append_only/requirement_deleted")

      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed(
            [decision],
            %{"specled.decision.adr_x" => adr},
            [inline, orphan]
          )
        )

      # Orphan in the top subsection
      assert html =~ "Governance violations (1)"
      assert html =~ "append_only/requirement_deleted"
      # Inline under the ADR card
      assert html =~ "Governance findings naming this ADR"
      assert html =~ "append_only/adr_affects_widened"
    end

    test "non-append_only findings are ignored by the Decisions panel" do
      noise = %{
        "code" => "branch_guard_realization_drift",
        "severity" => "error",
        "subject_id" => "x",
        "entity_id" => "x.req_a",
        "message" => "drift"
      }

      html = IO.iodata_to_binary(Html.render_decisions_changed([], %{}, [noise]))

      assert html =~ "Decisions changed (0)"
      refute html =~ "Governance violations"
      refute html =~ "branch_guard_realization_drift"
    end
  end
end
