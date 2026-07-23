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
            c.leg == "Spec → Code" and
              c.codes == ~w(branch_guard_realization_drift branch_guard_dangling_binding)
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

  describe "render_findings_list — leg + severity grouping" do
    # The global findings list groups findings by triangle leg first, then
    # by severity within each leg, with counts in each heading. The leg
    # mapping reuses build_sync_checks (the sync checklist's source of
    # truth) rather than maintaining a parallel table.

    defp leg_finding(code, severity, opts \\ []) do
      %{
        "code" => code,
        "severity" => severity,
        "subject_id" => Keyword.get(opts, :subject_id),
        "message" => Keyword.get(opts, :message, "msg for #{code}")
      }
    end

    test "an empty list renders nothing" do
      assert Html.render_findings_list([]) == ""
    end

    test "leg_for_finding_code reuses the sync-checklist code-to-leg mapping" do
      # Each leg bucket has at least one canonical code that the existing
      # sync checklist (build_sync_checks) already classifies. If those
      # mappings ever drift, this test pins the contract.
      assert Html.leg_for_finding_code("overlap/duplicate_covers") == "Spec well-formed"
      assert Html.leg_for_finding_code("branch_guard_realization_drift") == "Spec ↔ Code"
      assert Html.leg_for_finding_code("requirement_without_test_tag") == "Spec ↔ Tests"
      assert Html.leg_for_finding_code("branch_guard_untethered_test") == "Code ↔ Tests"
      assert Html.leg_for_finding_code("verification_strength_below_minimum") == "Coverage"
      assert Html.leg_for_finding_code("append_only/requirement_deleted") == "Decisions"
      assert Html.leg_for_finding_code("branch_guard_unmapped_change") == "Branch"
    end

    test "code_to_leg_lookup is sourced from build_sync_checks (no duplication)" do
      # Walk the sync checklist directly and confirm every code it knows
      # appears in the global-list lookup, mapped to a known bucket. This
      # is the audit knob that prevents accidental drift between the two.
      zeroed = %{
        findings_by_code: %{},
        affected_subject_count: 0,
        binding_count: 0,
        requirement_count: 0,
        verification_count: 0,
        adr_ref_count: 0,
        strength_breakdown: %{}
      }

      lookup = Html.code_to_leg_lookup()

      buckets = [
        "Spec well-formed",
        "Spec ↔ Code",
        "Spec ↔ Tests",
        "Code ↔ Tests",
        "Coverage",
        "Decisions",
        "Branch"
      ]

      for check <- Html.build_sync_checks(zeroed),
          code <- check.codes do
        assert Map.has_key?(lookup, code),
               "code #{code} from sync-check leg #{inspect(check.leg)} is not in code_to_leg_lookup"

        assert Map.get(lookup, code) in buckets,
               "code #{code} mapped to unexpected bucket #{inspect(Map.get(lookup, code))}"
      end
    end

    test "an unknown code falls into the 'Other' bucket" do
      assert Html.leg_for_finding_code("totally_made_up_code") == "Other"
    end

    test "groups appear in the canonical leg order" do
      findings = [
        leg_finding("branch_guard_unmapped_change", "warning"),
        leg_finding("branch_guard_realization_drift", "error"),
        leg_finding("overlap/duplicate_covers", "error"),
        leg_finding("requirement_without_test_tag", "warning")
      ]

      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      # Index of each leg heading in the rendered HTML — must follow the
      # canonical order: Spec well-formed, Spec ↔ Code, Spec ↔ Tests, ...
      indices =
        for leg <- ["Spec well-formed", "Spec ↔ Code", "Spec ↔ Tests", "Branch"] do
          {leg, :binary.match(html, leg)}
        end

      Enum.each(indices, fn {leg, m} ->
        refute m == :nomatch, "expected leg #{inspect(leg)} to render"
      end)

      offsets = Enum.map(indices, fn {_, {pos, _}} -> pos end)
      assert offsets == Enum.sort(offsets), "groups did not render in canonical order"
    end

    test "each group heading shows total count and per-severity counts" do
      findings = [
        leg_finding("branch_guard_realization_drift", "error"),
        leg_finding("branch_guard_realization_drift", "error"),
        leg_finding("branch_guard_dangling_binding", "warning")
      ]

      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      assert html =~ ~s|<h3 class="findings-group-heading">|
      assert html =~ ~s|<span class="findings-group-leg">Spec ↔ Code</span>|
      assert html =~ "3 findings"
      assert html =~ ~s|findings-group-sev-error|
      assert html =~ "2 error"
      assert html =~ ~s|findings-group-sev-warning|
      assert html =~ "1 warning"
    end

    test "within a group, errors render before warnings before info" do
      findings = [
        leg_finding("branch_guard_realization_drift", "info", message: "info-finding"),
        leg_finding("branch_guard_realization_drift", "warning", message: "warn-finding"),
        leg_finding("branch_guard_realization_drift", "error", message: "err-finding")
      ]

      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      err_pos = :binary.match(html, "err-finding") |> elem(0)
      warn_pos = :binary.match(html, "warn-finding") |> elem(0)
      info_pos = :binary.match(html, "info-finding") |> elem(0)

      assert err_pos < warn_pos
      assert warn_pos < info_pos
    end

    test "each finding still uses the tooltip(:severity, sev) mechanism" do
      findings = [leg_finding("branch_guard_realization_drift", "error")]
      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      # The severity span must carry the tooltip text from
      # tooltip(:severity, "error") — same mechanism the original list used.
      assert html =~ "Error — blocks the gate"
    end

    test "the heading severity chip also carries the severity tooltip" do
      findings = [leg_finding("branch_guard_realization_drift", "warning")]
      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      # The "1 warning" chip in the group heading must carry the warning
      # tooltip — the ticket calls out reusing tooltip(:severity, sev).
      assert html =~ ~s|findings-group-sev-warning|
      assert html =~ "Warning"
    end

    test "an unclassifiable code lands in the 'Other' bucket at the end" do
      findings = [
        leg_finding("not_a_known_code", "warning"),
        leg_finding("branch_guard_realization_drift", "error")
      ]

      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      spec_code_pos = :binary.match(html, "Spec ↔ Code") |> elem(0)
      other_pos = :binary.match(html, "Other") |> elem(0)

      assert spec_code_pos < other_pos
    end

    test "the outer summary shows the total finding count" do
      findings = [
        leg_finding("branch_guard_realization_drift", "error"),
        leg_finding("branch_guard_unmapped_change", "warning"),
        leg_finding("requirement_without_test_tag", "warning")
      ]

      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      assert html =~ "All findings (3)"
    end

    test "groups with no findings do not render" do
      findings = [leg_finding("branch_guard_realization_drift", "error")]
      html = IO.iodata_to_binary(Html.render_findings_list(findings))

      # Only the Spec ↔ Code group should be present; no Coverage / Branch / etc.
      refute html =~ ~s|<span class="findings-group-leg">Coverage</span>|
      refute html =~ ~s|<span class="findings-group-leg">Branch</span>|
      refute html =~ ~s|<span class="findings-group-leg">Decisions</span>|
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

    @tag spec: "specled.spec_review.decisions_governance_inline"
    test "a removed ADR renders with a REMOVED chip and a deletion note around its base content" do
      decision = %{
        id: "specled.decision.gone",
        file: ".spec/decisions/gone.md",
        status: "accepted",
        change_type: nil,
        affects: ["x.req_a"],
        deleted?: true
      }

      adr = %{
        id: "specled.decision.gone",
        file: ".spec/decisions/gone.md",
        title: "Gone Decision",
        status: "accepted",
        date: "2026-01-01",
        change_type: nil,
        affects: ["x.req_a"],
        body_text: "## Context\n\nWhy it existed.",
        change_status: :removed
      }

      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed([decision], %{"specled.decision.gone" => adr}, [])
        )

      assert html =~ "REMOVED"
      assert html =~ "Gone Decision"
      assert html =~ "deleted in this change set"
      assert html =~ "Why it existed."
      refute html =~ "no parsed ADR available"
    end

    @tag spec: "specled.spec_review.decisions_governance_inline"
    test "a deleted decision with no parseable base still says deleted, not 'no parsed ADR'" do
      decision = %{
        id: nil,
        file: ".spec/decisions/mystery.md",
        status: nil,
        change_type: nil,
        affects: [],
        deleted?: true
      }

      html = IO.iodata_to_binary(Html.render_decisions_changed([decision], %{}, []))

      assert html =~ "REMOVED"
      assert html =~ "decision file deleted in this change set"
      refute html =~ "decision changed but no parsed ADR available"
    end

    @tag spec: "specled.spec_review.decisions_governance_inline"
    test "a modified ADR renders a section-level body diff instead of the plain document" do
      base = """
      ## Context

      Original context prose.

      ## Decision

      We use approach A.

      ## Consequences

      Cheap to operate.
      """

      head = """
      ## Context

      Original context prose.

      ## Decision

      We use approach A with batching.

      ## Consequences

      Cheap to operate.

      ## Update (2026-07-01)

      Approach A survived the audit.
      """

      decision = %{
        id: "specled.decision.evolving",
        file: ".spec/decisions/evolving.md",
        status: "accepted",
        change_type: "refines",
        affects: [],
        deleted?: false
      }

      adr = %{
        id: "specled.decision.evolving",
        file: ".spec/decisions/evolving.md",
        title: "Evolving Decision",
        status: "accepted",
        date: "2026-01-01",
        change_type: "refines",
        affects: [],
        body_text: head,
        base_body_text: base,
        change_status: :modified
      }

      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed([decision], %{"specled.decision.evolving" => adr}, [])
        )

      # The appended Update section is chipped ADDED; the edited Decision
      # section is chipped MODIFIED with inline wording del/ins; the untouched
      # Context section renders as plain markdown without a chip wrapper.
      assert html =~ "adr-section-added"
      assert html =~ "Update (2026-07-01)"
      assert html =~ "adr-section-modified"
      assert html =~ ~s|<ins class="wording-ins">|
      refute html =~ "adr-section-removed"
    end

    @tag spec: "specled.spec_review.decisions_governance_inline"
    test "[[wiki-links]] in ADR prose render as in-page anchors, but not inside code spans" do
      decision = %{
        id: "specled.decision.linker",
        file: ".spec/decisions/linker.md",
        status: "accepted",
        change_type: nil,
        affects: [],
        deleted?: false
      }

      adr = %{
        id: "specled.decision.linker",
        file: ".spec/decisions/linker.md",
        title: "Linker",
        status: "accepted",
        date: nil,
        change_type: nil,
        affects: [],
        body_text:
          "## Context\n\nSee [[atlas.decision.expansion_rerank_deleted]] for the audit.\nLiteral in code: `[[not.a.link]]`.",
        change_status: :new
      }

      html =
        IO.iodata_to_binary(
          Html.render_decisions_changed([decision], %{"specled.decision.linker" => adr}, [])
        )

      assert html =~
               ~s|<a class="wikilink" href="#adr-atlas-decision-expansion-rerank-deleted"><code>atlas.decision.expansion_rerank_deleted</code></a>|

      # The code-span occurrence stays literal.
      assert html =~ "[[not.a.link]]"
      refute html =~ ~s|href="#adr-not-a-link"|
    end

    @tag spec: "specled.spec_review.decisions_governance_inline"
    test "a section deleted from an ADR body renders as a REMOVED section block" do
      html =
        IO.iodata_to_binary(
          Html.render_adr_body_diff(
            "## Context\n\nKept.\n\n## Obsolete\n\nDrop this rationale.\n",
            "## Context\n\nKept.\n"
          )
        )

      assert html =~ "adr-section-removed"
      assert html =~ "Drop this rationale."
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

  defp render_findings(findings), do: IO.iodata_to_binary(Html.render_findings_list(findings))

  defp untethered_finding(claimed, observed_owners, opts \\ []) do
    %{
      "code" => "branch_guard_untethered_test",
      "severity" => Keyword.get(opts, :severity, "info"),
      "subject_id" => claimed,
      "observed_owners" => observed_owners,
      "message" =>
        Keyword.get(
          opts,
          :message,
          "test claims #{claimed} but hits #{Enum.join(observed_owners, ", ")}"
        )
    }
  end

  describe "render_findings_list — untethered_test claims/hits link" do
    # A branch_guard_untethered_test finding's `subject_id` is the *claimed*
    # subject (the one the test's `@tag spec:` named) while the test's
    # coverage actually exercises a different subject — recorded in
    # `observed_owners`. The reviewer needs both anchors so the misalignment
    # IS the headline; linking only to the claimed subject sends them to a
    # card with no evidence.

    test "renders 'claims A, hits B' with anchors to both subjects when observed_owners present" do
      html = render_findings([untethered_finding("subject.a", ["subject.b"], message: "...")])

      assert html =~ "finding-subject-pair"
      assert html =~ ~s|<span class="finding-subject-label">claims</span>|
      assert html =~ ~s|<span class="finding-subject-label">, hits</span>|
      assert html =~ ~s|href="#subject-subject-a"|
      assert html =~ ~s|href="#subject-subject-b"|
      assert html =~ ">subject.a<"
      assert html =~ ">subject.b<"
    end

    test "preserves order: claimed appears before observed in the rendered string" do
      html = render_findings([untethered_finding("subject.a", ["subject.b"])])

      claimed_pos = :binary.match(html, "subject-subject-a") |> elem(0)
      observed_pos = :binary.match(html, "subject-subject-b") |> elem(0)

      assert claimed_pos < observed_pos,
             "claimed subject should be rendered before observed owner"
    end

    test "renders multiple observed owners as comma-separated anchors" do
      html = render_findings([untethered_finding("subject.a", ["subject.b", "subject.c"])])

      assert html =~ ~s|href="#subject-subject-a"|
      assert html =~ ~s|href="#subject-subject-b"|
      assert html =~ ~s|href="#subject-subject-c"|
    end

    test "falls back to single claimed link when observed_owners is missing" do
      finding = %{
        "code" => "branch_guard_untethered_test",
        "severity" => "info",
        "subject_id" => "subject.a",
        "message" => "..."
      }

      html = render_findings([finding])

      assert html =~ ~s|href="#subject-subject-a"|
      refute html =~ "finding-subject-pair"
      refute html =~ "finding-subject-label"
    end

    test "falls back to single claimed link when observed_owners is empty list" do
      html = render_findings([untethered_finding("subject.a", [], message: "...")])

      assert html =~ ~s|href="#subject-subject-a"|
      refute html =~ "finding-subject-pair"
      refute html =~ "finding-subject-label"
    end

    test "non-untethered findings still render a single subject link" do
      finding = %{
        "code" => "branch_guard_untested_realization",
        "severity" => "warning",
        "subject_id" => "subject.a",
        "observed_owners" => ["subject.b"],
        "message" => "..."
      }

      html = render_findings([finding])

      assert html =~ ~s|href="#subject-subject-a"|
      refute html =~ ~s|href="#subject-subject-b"|
      refute html =~ "finding-subject-pair"
      refute html =~ "finding-subject-label"
    end

    test "untethered finding without subject_id still renders observed owners" do
      finding = %{
        "code" => "branch_guard_untethered_test",
        "severity" => "info",
        "subject_id" => nil,
        "observed_owners" => ["subject.b"],
        "message" => "..."
      }

      html = render_findings([finding])

      assert html =~ ~s|href="#subject-subject-b"|
    end
  end

  # covers: specled.spec_review.coverage_tab_bind_closure
  describe "render_coverage_tab — v2 envelope bind-closure view" do
    defp coverage_subject(opts) do
      %{
        id: Keyword.get(opts, :id, "subj.a"),
        bindings: Keyword.get(opts, :bindings, %{}),
        requirements:
          Keyword.get(opts, :requirements, [
            %{
              "id" => "subj.a.req1",
              "statement" => "First requirement statement.",
              "priority" => "must"
            },
            %{
              "id" => "subj.a.req2",
              "statement" => "Second requirement statement.",
              "priority" => "must"
            }
          ]),
        claims_by_req: Keyword.get(opts, :claims_by_req, %{}),
        closure_reach:
          Keyword.get(opts, :closure_reach, %{status: :ok_aggregate, by_requirement: %{}}),
        coverage_generated_at: Keyword.get(opts, :coverage_generated_at)
      }
    end

    defp req_reach(overrides) do
      Map.merge(
        %{
          closure_mfa_count: 4,
          closure_coverage_pct: 75.0,
          covered_mfas: ["Mod.a/1", "Mod.b/1", "Mod.c/1"],
          uncovered_mfas: ["Mod.d/1"],
          tagged_tests: [],
          self_verified?: false
        },
        Map.new(overrides)
      )
    end

    test "aggregate mode renders \"Closure: N MFAs — K executed (X.X%). Self-verified: yes/no. Tagged tests: …\"" do
      reach = %{
        status: :ok_aggregate,
        by_requirement: %{
          "subj.a.req1" =>
            req_reach(
              tagged_tests: [
                %{file: "test/a_test.exs", test_name: "t1", strength: "linked"},
                %{file: "test/b_test.exs", test_name: "t2", strength: "claimed"}
              ]
            ),
          "subj.a.req2" =>
            req_reach(closure_mfa_count: 1, closure_coverage_pct: 0.0, covered_mfas: [])
        }
      }

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "Closure:</span> 4 MFAs — 3 executed (75.0%)."
      assert html =~ "Self-verified: no."
      assert html =~ "test/a_test.exs :: t1</code> (linked)"
      assert html =~ "test/b_test.exs :: t2</code> (claimed)"
      assert html =~ "Closure:</span> 1 MFA — 0 executed (0.0%)."

      # Aggregate mode has no per-test attribution, so evidence never
      # reaches "executed" and the mode-gated row does not render.
      refute html =~ "Reached by tests"
      # Aggregate mode's covered_mfas come straight from the envelope, not a
      # file-level proxy, so the qualifier does not render.
      refute html =~ "file-level proxy"
    end

    test "self-verified renders yes when self_verified? is true, with an executed tagged test" do
      reach = %{
        status: :ok_per_test,
        by_requirement: %{
          "subj.a.req1" =>
            req_reach(
              self_verified?: true,
              tagged_tests: [%{file: "test/a_test.exs", test_name: "t1", strength: "executed"}]
            )
        }
      }

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(
            coverage_subject(
              closure_reach: reach,
              requirements: [
                %{"id" => "subj.a.req1", "statement" => "S", "priority" => "must"}
              ]
            )
          )
        )

      assert html =~ "Self-verified: yes."
      assert html =~ "test/a_test.exs :: t1</code> (executed)"
    end

    test "\"Reached by tests\" row renders only in per_test mode, naming executed tagged tests" do
      reach = %{
        status: :ok_per_test,
        by_requirement: %{
          "subj.a.req1" =>
            req_reach(
              self_verified?: true,
              tagged_tests: [
                %{file: "test/a_test.exs", test_name: "t1", strength: "executed"},
                %{file: "test/b_test.exs", test_name: "t2", strength: "linked"}
              ]
            )
        }
      }

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(
            coverage_subject(
              closure_reach: reach,
              requirements: [
                %{"id" => "subj.a.req1", "statement" => "S", "priority" => "must"}
              ]
            )
          )
        )

      assert html =~
               "Reached by tests:</span> <code class=\"cov-closure-test\">test/a_test.exs :: t1</code>."

      # The non-executed tagged test is not listed on the reached-by row (it
      # still appears in the "Tagged tests" line above).
      refute html =~
               "Reached by tests:</span> <code class=\"cov-closure-test\">test/a_test.exs :: t1</code>, <code class=\"cov-closure-test\">test/b_test.exs :: t2</code>."
    end

    test "per_test mode carries a file-level-proxy qualifier on the closure line" do
      reach = %{
        status: :ok_per_test,
        by_requirement: %{"subj.a.req1" => req_reach(tagged_tests: [])}
      }

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(
            coverage_subject(
              closure_reach: reach,
              requirements: [
                %{"id" => "subj.a.req1", "statement" => "S", "priority" => "must"}
              ]
            )
          )
        )

      assert html =~ "file-level proxy"
    end

    test "renders the empty-closure form when the requirement has no closure MFAs" do
      reach = %{
        status: :ok_aggregate,
        by_requirement: %{
          "subj.a.req1" =>
            req_reach(
              closure_mfa_count: 0,
              closure_coverage_pct: :no_closure_mfas,
              covered_mfas: [],
              uncovered_mfas: []
            )
        }
      }

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(
            coverage_subject(
              closure_reach: reach,
              requirements: [
                %{"id" => "subj.a.req1", "statement" => "S", "priority" => "must"}
              ]
            )
          )
        )

      assert html =~ ~s|class="cov-closure" data-empty="true"|
      assert html =~ "Closure:</span> 0 MFAs."
    end

    test "renders the \"coverage artifact unavailable\" banner when status is :no_coverage_artifact" do
      reach = %{status: :no_coverage_artifact, by_requirement: %{}}

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "Coverage artifact unavailable"
      assert html =~ "mix spec.cover.test"
      # Per-row closure lines are suppressed when the artifact is missing —
      # the page-level degraded banner already advertises the situation.
      refute html =~ ~s|class="cov-closure"|
    end

    test "renders the \"binding closure unavailable\" banner when status is :no_tracer_manifest" do
      reach = %{status: :no_tracer_manifest, by_requirement: %{}}

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "Binding closure unavailable"
      assert html =~ "tracer manifest"
      refute html =~ ~s|class="cov-closure"|
    end

    test "renders a distinct banner naming mix spec.cover.test when status is :legacy_artifact" do
      reach = %{status: :legacy_artifact, by_requirement: %{}}

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "legacy format"
      assert html =~ "mix spec.cover.test"
      refute html =~ "Coverage artifact unavailable"
      refute html =~ ~s|class="cov-closure"|
    end

    test "renders a distinct banner when status is :invalid_artifact" do
      reach = %{status: :invalid_artifact, by_requirement: %{}}

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "invalid"
      refute html =~ "Coverage artifact unavailable"
      refute html =~ "legacy format"
      refute html =~ ~s|class="cov-closure"|
    end

    test "renders a distinct degraded banner when status is :async_contaminated (flag 1)" do
      reach = %{status: :async_contaminated, by_requirement: %{}}

      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject(closure_reach: reach)))

      assert html =~ "degraded"
      assert html =~ "async contamination"
      refute html =~ "Coverage artifact unavailable"
      refute html =~ ~s|class="cov-closure"|
    end

    test "renders the coverage artifact's generated_at with an elapsed-time note" do
      generated_at = DateTime.add(DateTime.utc_now(), -300, :second)

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(coverage_subject(coverage_generated_at: generated_at))
        )

      assert html =~ "Coverage captured"
      assert html =~ "5m ago"
      refute html =~ "possibly stale"
    end

    test "flags the generated_at note as possibly stale past the age threshold" do
      generated_at = DateTime.add(DateTime.utc_now(), -2 * 24 * 60 * 60, :second)

      html =
        IO.iodata_to_binary(
          Html.render_coverage_tab(coverage_subject(coverage_generated_at: generated_at))
        )

      assert html =~ "possibly stale"
      assert html =~ ~s|class="cov-generated-at cov-generated-stale"|
    end

    test "renders no generated_at note when the timestamp is absent" do
      html = IO.iodata_to_binary(Html.render_coverage_tab(coverage_subject([])))

      refute html =~ "Coverage captured"
    end

    test "is backwards-compatible when the subject view-model has no closure_reach key" do
      subject = %{
        id: "subj.a",
        bindings: %{},
        requirements: [
          %{"id" => "subj.a.req1", "statement" => "S", "priority" => "must"}
        ],
        claims_by_req: %{}
      }

      # No raise; the requirement renders without a closure summary.
      html = IO.iodata_to_binary(Html.render_coverage_tab(subject))

      assert html =~ "subj.a.req1"
      refute html =~ ~s|class="cov-closure"|
      refute html =~ "Coverage artifact unavailable"
    end
  end

  # covers: specled.spec_review.coverage_tab_v2_envelope_data_layer
  describe "render_subject_coverage_badge — subject-card rollup badge" do
    test "renders a self-verified/total count and mode label when coverage data loaded" do
      reach = %{
        status: :ok_per_test,
        by_requirement: %{
          "a" => %{self_verified?: true},
          "b" => %{self_verified?: false}
        }
      }

      html = IO.iodata_to_binary(Html.render_subject_coverage_badge(reach))

      assert html =~ "badge-coverage-rollup"
      assert html =~ "1/2 self-verified (per-test)"
    end

    test "renders a muted coverage-unavailable chip for each degraded status" do
      for status <- [
            :no_coverage_artifact,
            :legacy_artifact,
            :invalid_artifact,
            :no_tracer_manifest,
            :async_contaminated
          ] do
        html =
          IO.iodata_to_binary(
            Html.render_subject_coverage_badge(%{status: status, by_requirement: %{}})
          )

        assert html =~ "badge-coverage-unavailable", "expected unavailable badge for #{status}"
        assert html =~ "coverage unavailable"
      end
    end
  end
end
