defmodule SpecLedEx.Review.Html do
  @moduledoc """
  Renders a `SpecLedEx.Review.build_view/3` view-model as a self-contained
  HTML string. CSS and JS are embedded inline so the artifact has no
  network dependency at view time.

  This module does no data fetching of its own — feed it the assembled
  view-model and it returns iodata.
  """

  require EEx

  # Vendored Prism.js bundle for syntax highlighting in the diff view.
  # Read at compile-time so the runtime artifact stays self-contained.
  @prism_assets_dir Path.join([__DIR__, "..", "..", "..", "priv", "spec_review_assets"])
                    |> Path.expand()

  @prism_files [
    "prism.min.js",
    "prism-markup.min.js",
    "prism-css.min.js",
    "prism-erlang.min.js",
    "prism-elixir.min.js",
    "prism-json.min.js",
    "prism-yaml.min.js",
    "prism-markdown.min.js",
    "prism-bash.min.js",
    "prism-diff.min.js"
  ]

  for f <- @prism_files do
    @external_resource Path.join(@prism_assets_dir, f)
  end

  @external_resource Path.join(@prism_assets_dir, "prism.css")

  @prism_js Enum.map_join(@prism_files, "\n", fn f ->
              File.read!(Path.join(@prism_assets_dir, f))
            end)

  @prism_css File.read!(Path.join(@prism_assets_dir, "prism.css"))

  # covers: specled.spec_review.html_artifact
  # All CSS and JS are embedded in the document; no <link> or <script src>
  # tags reach the network. The artifact renders identically offline.
  #
  # covers: specled.spec_review.read_only_viewer
  # No <form>, <input>, or <button> that posts state. The HTML is a pure
  # viewer; reviewer approval lives on the host platform's existing flow.
  @spec render(map()) :: iodata()
  def render(view) do
    [
      "<!DOCTYPE html>\n",
      page(view, css(), js())
    ]
  end

  EEx.function_from_string(:defp, :page, ~S"""
  <html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Spec Review · <%= h(view.meta.head_ref) %></title>
    <style><%= prism_css() %></style>
    <style><%= css %></style>
  </head>
  <body>
    <header class="page-header">
      <div class="page-header-row">
        <h1>Spec Review</h1>
        <div class="page-header-meta">
          <%= render_diff_stats(view.meta.stats) %>
          <span class="ref"><%= h(view.meta.base_ref) %><span class="ref-sep">…</span><%= h(view.meta.head_ref) %></span>
          <span class="generated"><%= h(format_dt(view.meta.generated_at)) %></span>
        </div>
      </div>
      <div class="view-toggle-wrap">
        <div class="view-toggle" role="tablist" aria-label="Review mode">
          <button class="view-toggle-btn active" type="button" role="tab" data-view="spec" aria-selected="true">
            <span class="view-toggle-label">Spec view</span>
            <span class="view-toggle-hint">grouped by subject, with triangulation</span>
          </button>
          <button class="view-toggle-btn" type="button" role="tab" data-view="files" aria-selected="false">
            <span class="view-toggle-label">Files view</span>
            <span class="view-toggle-hint">flat diff of all changed files</span>
          </button>
        </div>
      </div>
    </header>
    <div class="layout" data-view-mode="spec">
      <aside class="toc" aria-label="Table of contents">
        <%= render_toc(view) %>
      </aside>
      <main>
        <section class="view-pane view-pane-spec active" data-view-pane="spec">
          <%= render_triage(view.triage, view.all_findings) %>
          <%= render_coverage_help_disclosure() %>
          <%= render_decisions_changed(view.decisions_changed, view.adrs_by_id) %>
          <%= render_subjects(view.affected_subjects, view.adrs_by_id) %>
          <%= render_unmapped(view.unmapped_changes, view.file_breakdown) %>
          <%= render_raw_verification_all(view.affected_subjects) %>
        </section>
        <section class="view-pane view-pane-files" data-view-pane="files">
          <%= render_files_view(view.all_changes, view.meta.stats) %>
        </section>
      </main>
    </div>
    <footer class="page-footer">
      <span>specled_ex · spec.review</span>
    </footer>
    <script><%= prism_js() %></script>
    <script><%= js %></script>
  </body>
  </html>
  """, [:view, :css, :js])

  @doc false
  def prism_js, do: @prism_js
  @doc false
  def prism_css, do: @prism_css

  defp render_toc(view) do
    [
      ~S|<nav><ul class="toc-list">|,
      toc_item("triage", "Triage", triage_toc_badge(view.triage)),
      render_toc_decisions(view.decisions_changed, view.adrs_by_id),
      ~s|<li class="toc-section"><a href="#subjects">Affected subjects (#{view.triage.affected_subject_count})</a>|,
      if view.triage.affected_subjects == [] do
        ""
      else
        [
          ~S|<ul class="toc-sublist">|,
          Enum.map(view.triage.affected_subjects, fn s ->
            ~s|<li><a href="#subject-#{slug(s.id)}"><code>#{h(s.id)}</code><span class="toc-pips">#{render_toc_change_pip(s)}#{render_toc_finding_badge(s)}</span></a></li>|
          end),
          ~S|</ul>|
        ]
      end,
      ~S|</li>|,
      toc_item("misc", "Outside the spec system (#{length(view.unmapped_changes)})", ""),
      ~S|</ul></nav>|
    ]
  end

  defp render_toc_decisions([], _adrs_by_id) do
    ~s|<li class="toc-section"><a href="#decisions-changed">Decisions changed (0)</a></li>|
  end

  defp render_toc_decisions(decisions, adrs_by_id) do
    [
      ~s|<li class="toc-section"><a href="#decisions-changed">Decisions changed (#{length(decisions)})</a>|,
      ~S|<ul class="toc-sublist">|,
      Enum.map(decisions, fn d ->
        adr = Map.get(adrs_by_id || %{}, d.id)
        anchor = "adr-" <> slug(d.id || d.file)
        pip = render_toc_adr_pip(adr)
        label = d.id || Path.basename(d.file)

        ~s|<li><a href="##{anchor}"><code>#{h(label)}</code><span class="toc-pips">#{pip}</span></a></li>|
      end),
      ~S|</ul>|,
      ~S|</li>|
    ]
  end

  defp render_toc_adr_pip(nil), do: ""

  defp render_toc_adr_pip(adr) do
    case Map.get(adr, :change_status) do
      :new ->
        ~s|<span class="toc-pip toc-pip-new"#{title_attr(tooltip(:change, :new))}>NEW</span>|

      :modified ->
        ~s|<span class="toc-pip toc-pip-edited"#{title_attr(tooltip(:change, :modified))}>EDITED</span>|

      :removed ->
        ~s|<span class="toc-pip toc-pip-error"#{title_attr(tooltip(:change, :removed))}>REM</span>|

      _ ->
        ""
    end
  end

  defp toc_item(anchor, label, badge) do
    ~s|<li class="toc-section"><a href="##{anchor}">#{h(label)}#{badge}</a></li>|
  end

  defp triage_toc_badge(%{clean?: true}), do: ~s| <span class="toc-pip toc-pip-clean">✓</span>|

  defp triage_toc_badge(%{findings_count: 0}), do: ""

  defp triage_toc_badge(triage) do
    cond do
      Map.get(triage.by_severity, "error", 0) > 0 ->
        ~s| <span class="toc-pip toc-pip-error">#{triage.findings_count}</span>|

      Map.get(triage.by_severity, "warning", 0) > 0 ->
        ~s| <span class="toc-pip toc-pip-warning">#{triage.findings_count}</span>|

      true ->
        ~s| <span class="toc-pip toc-pip-info">#{triage.findings_count}</span>|
    end
  end

  defp render_toc_finding_badge(%{findings_count: 0}), do: ""

  defp render_toc_finding_badge(%{by_severity: by_sev, findings_count: count}) do
    cond do
      Map.get(by_sev, "error", 0) > 0 -> ~s|<span class="toc-pip toc-pip-error">#{count}</span>|
      Map.get(by_sev, "warning", 0) > 0 -> ~s|<span class="toc-pip toc-pip-warning">#{count}</span>|
      true -> ~s|<span class="toc-pip toc-pip-info">#{count}</span>|
    end
  end

  defp render_toc_change_pip(%{change_status: :new}),
    do:
      ~s|<span class="toc-pip toc-pip-new"#{title_attr(tooltip(:change, :new_subject))}>NEW</span>|

  defp render_toc_change_pip(%{change_status: :edited}),
    do:
      ~s|<span class="toc-pip toc-pip-edited"#{title_attr(tooltip(:change, :spec_edited))}>EDITED</span>|

  defp render_toc_change_pip(_), do: ""

  # covers: specled.spec_review.triage_panel
  # The sync-status panel headlines whether spec ↔ code ↔ tests ↔ coverage
  # are in sync for this change set, then enumerates the specific checks
  # that were performed (so a first-time reader can see what "no findings"
  # actually means). Per-subject status badges and the full findings list
  # remain available below.
  defp render_triage(%{clean?: true} = triage, _findings) do
    [
      ~s|<section id="triage" class="sync-status sync-status-in" aria-label="Sync status">|,
      render_sync_headline(triage, true),
      render_sync_checklist(triage),
      ~S|</section>|
    ]
  end

  defp render_triage(triage, findings) do
    in_sync? = triage.findings_count == 0
    state = if in_sync?, do: "in", else: "out"

    [
      ~s|<section id="triage" class="sync-status sync-status-#{state}" aria-label="Sync status">|,
      render_sync_headline(triage, in_sync?),
      render_sync_checklist(triage),
      render_triage_subjects(triage.affected_subjects),
      render_findings_list(findings),
      ~S|</section>|
    ]
  end

  defp render_sync_headline(triage, in_sync?) do
    {icon, icon_class, title} =
      if in_sync? do
        {"✓", "sync-headline-icon-ok", "In sync"}
      else
        {"⚠", "sync-headline-icon-fail",
         "Out of sync — #{triage.findings_count} finding#{maybe_s(triage.findings_count)}"}
      end

    ~s"""
    <header class="sync-headline">
      #{render_degraded_banner(triage)}
      <div class="sync-headline-row">
        <span class="sync-headline-icon #{icon_class}" aria-hidden="true">#{icon}</span>
        <div class="sync-headline-text">
          <h2 class="sync-headline-title">#{h(title)}</h2>
          <p class="sync-headline-meta">#{render_sync_meta(triage)}</p>
        </div>
      </div>
      #{render_sync_diagram(triage, in_sync?)}
    </header>
    """
  end

  # covers: specled.spec_review.degraded_leg_state
  # When any triangle leg is degraded by a `detector_unavailable` finding
  # the reviewer should see immediately that the report is partial — no
  # amount of green ✓s on adjacent legs makes a missing leg "fine."
  @doc false
  def render_degraded_banner(triage) do
    reasons =
      triage
      |> Map.get(:detector_unavailable_by_leg, %{})
      |> Map.values()
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.sort()

    case reasons do
      [] ->
        ""

      reasons ->
        formatted =
          reasons
          |> Enum.map(&"<code>#{h(&1)}</code>")
          |> Enum.join(", ")

        ~s|<div class="sync-degraded-banner" role="status"><span class="sync-degraded-icon" aria-hidden="true">?</span><span class="sync-degraded-text">Partial report — one or more triangle legs could not be checked on this run (#{formatted}). Re-run with the missing detector input to verify these legs.</span></div>|
    end
  end

  # covers: specled.spec_review.triangle_code_classification
  # Triangle leg vocabulary mapped to the three sides of the spec/code/test
  # triangle described in docs/concepts.md. The diagram and the checklist
  # both feed off `findings_by_code`; together they advertise which side of
  # the triangle a finding lives on.
  @doc false
  def render_sync_diagram(triage, _in_sync? \\ false) do
    fbc = triage.findings_by_code

    # Triangle leg vocabulary, per docs/concepts.md:
    #   * SPEC ↔ CODE   — realized_by binding integrity (surfaces exist,
    #     hashes match, bindings point at live MFAs).
    #   * SPEC ↔ TESTS  — @tag spec claim integrity (every covered
    #     requirement is named by a test, every binding closure is
    #     exercised by some tagged test, and verification commands run).
    #   * CODE ↔ TESTS  — observed-coverage integrity (tests exercise the
    #     code their tag claims, MFAs aren't silently executed without an
    #     owning requirement, and strength minimums are met).
    spec_to_code_codes =
      ~w(
        surface_target_missing
        verification_target_missing
        verification_target_missing_file
        verification_target_missing_reference
        branch_guard_realization_drift
        branch_guard_dangling_binding
      )

    code_to_tests_codes =
      ~w(
        verification_command_failed
        branch_guard_untested_realization
        requirement_without_test_tag
        branch_guard_requirement_without_test_tag
      )

    tests_to_coverage_codes =
      ~w(
        verification_strength_below_minimum
        requirement_without_verification
        verification_unknown_cover
        branch_guard_untethered_test
        branch_guard_underspecified_realization
      )

    detector_by_leg = Map.get(triage, :detector_unavailable_by_leg, %{})
    spec_to_code_degraded = Map.get(detector_by_leg, :spec_to_code, %{})
    spec_to_tests_degraded = Map.get(detector_by_leg, :spec_to_tests, %{})
    tests_to_coverage_degraded = Map.get(detector_by_leg, :tests_to_coverage, %{})

    # Vacuous: the leg has nothing to verify on this PR. Reads as gray, not
    # green — vacuous truth should not look like a victory.
    # Degraded: the leg has a `detector_unavailable` finding (debug_info
    # stripped, umbrella unsupported, missing coverage artifact, …). Reads
    # as gray-yellow with a `?` glyph — the system is being honest that it
    # could not run the check.
    spec_to_code_state =
      leg_state(fbc, spec_to_code_codes, triage.binding_count == 0, map_size(spec_to_code_degraded) > 0)

    code_to_tests_state =
      leg_state(fbc, code_to_tests_codes, triage.binding_count == 0, map_size(spec_to_tests_degraded) > 0)

    tests_to_coverage_state =
      leg_state(fbc, tests_to_coverage_codes, triage.verification_count == 0,
        map_size(tests_to_coverage_degraded) > 0)

    nodes = [
      {"SPEC", "#{triage.affected_subject_count} subj · #{triage.requirement_count} req#{maybe_s(triage.requirement_count)}",
       triage.requirement_count == 0,
       "Requirements declared in your subject .spec.md files. Each is a normative claim the rest of the chain must back up."},
      {"CODE", "#{triage.binding_count} MFA#{maybe_s(triage.binding_count)}",
       triage.binding_count == 0,
       "Functions named in each subject's realized_by block. Specled checks they actually exist as exported functions in the codebase. \"0 MFAs\" means no affected subject declared a realized_by — there's nothing to verify on this leg, neither pass nor fail."},
      {"TESTS", "#{triage.verification_count} verif#{if triage.verification_count == 1, do: "", else: "s"}",
       triage.verification_count == 0,
       "Verification entries: tagged tests, file-existence checks, or commands that prove a requirement holds."},
      {"COVERAGE", strength_diagram_summary(triage.strength_breakdown),
       map_size(triage.strength_breakdown) == 0,
       "The strongest evidence collected per requirement: EXECUTED > LINKED > CLAIMED. The verifier picks the highest tier each requirement reaches."}
    ]

    edges = [
      {spec_to_code_state, "realized_by",
       "Spec → Code · Each requirement names the code that realizes it via the `realized_by` block, and those MFAs must exist in the codebase." <>
         degraded_tooltip_suffix(spec_to_code_degraded)},
      {code_to_tests_state, "@tag spec",
       "Code → Tests · The realized code is exercised by tests carrying `@tag spec: \"<requirement_id>\"` so coverage can be linked back to the spec." <>
         degraded_tooltip_suffix(spec_to_tests_degraded)},
      {tests_to_coverage_state, "evidence",
       "Tests → Coverage · Each verification entry produces evidence at the CLAIMED, LINKED, or EXECUTED tier; every requirement must reach its minimum strength." <>
         degraded_tooltip_suffix(tests_to_coverage_degraded)}
    ]

    rendered =
      [render_diagram_node(Enum.at(nodes, 0))] ++
        Enum.flat_map(0..2, fn i ->
          [
            render_diagram_edge(Enum.at(edges, i)),
            render_diagram_node(Enum.at(nodes, i + 1))
          ]
        end)

    ~s|<div class="sync-diagram" role="img" aria-label="Triangulation chain">#{IO.iodata_to_binary(rendered)}</div>|
  end

  # Quad-state per-leg evaluation. :vacuous means "nothing to verify on
  # this leg" — we should not render that as ✓ since there is no positive
  # evidence. :ok means "all relevant checks passed". :fail means "some
  # finding hit one of this leg's codes". :degraded means "the detector
  # for this leg could not run (e.g. detector_unavailable: debug_info_
  # stripped, umbrella_unsupported, no_coverage_artifact)" — neither
  # positive nor negative evidence; the system is being honest that the
  # check did not run. :fail wins over :degraded; :degraded wins over
  # :vacuous and :ok.
  # covers: specled.spec_review.degraded_leg_state
  defp leg_state(fbc, codes, vacuous?, degraded?) do
    cond do
      Enum.any?(codes, fn c -> Map.get(fbc, c, 0) > 0 end) -> :fail
      degraded? -> :degraded
      vacuous? -> :vacuous
      true -> :ok
    end
  end

  defp render_diagram_node({title, stat, empty?, tooltip}) do
    klass = if empty?, do: "sync-node sync-node-empty", else: "sync-node"

    ~s|<div class="#{klass}" title="#{html_escape(tooltip)}"><div class="sync-node-title">#{h(title)}</div><div class="sync-node-stat">#{h(stat)}</div></div>|
  end

  defp render_diagram_edge({state, label, tooltip}) do
    {state_class, icon} =
      case state do
        :ok -> {"ok", "✓"}
        :fail -> {"fail", "✗"}
        :degraded -> {"degraded", "?"}
        :vacuous -> {"vacuous", "—"}
      end

    ~s|<div class="sync-edge sync-edge-#{state_class}" title="#{html_escape(tooltip)}"><div class="sync-edge-line"></div><div class="sync-edge-label"><span class="sync-edge-icon">#{icon}</span> #{h(label)}</div></div>|
  end

  # Append a "Degraded: <reason>, <reason>" suffix to an edge tooltip when
  # the leg carries detector_unavailable findings. Reasons are rendered
  # verbatim (snake_case) since they're a fixed catalog the reviewer can
  # look up in docs/concepts.md.
  defp degraded_tooltip_suffix(reasons_map) when reasons_map == %{}, do: ""

  defp degraded_tooltip_suffix(reasons_map) when is_map(reasons_map) do
    reasons =
      reasons_map
      |> Map.keys()
      |> Enum.sort()
      |> Enum.join(", ")

    " · Degraded: #{reasons}"
  end

  defp strength_diagram_summary(breakdown) when is_map(breakdown) and map_size(breakdown) > 0 do
    [:executed, :linked, :claimed, :uncovered]
    |> Enum.map(fn k -> {k, Map.get(breakdown, k, 0)} end)
    |> Enum.reject(fn {_, n} -> n == 0 end)
    |> Enum.map_join(" · ", fn {k, n} -> "#{n}#{strength_short(k)}" end)
  end

  defp strength_diagram_summary(_), do: "—"

  defp strength_short(:executed), do: "E"
  defp strength_short(:linked), do: "L"
  defp strength_short(:claimed), do: "C"
  defp strength_short(:uncovered), do: "U"

  defp render_sync_meta(triage) do
    parts = [
      "#{triage.affected_subject_count} subject#{maybe_s(triage.affected_subject_count)}",
      "#{triage.requirement_count} requirement#{maybe_s(triage.requirement_count)}",
      "#{triage.binding_count} binding#{maybe_s(triage.binding_count)}",
      strength_summary_text(triage.strength_breakdown)
    ]

    parts
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp strength_summary_text(breakdown) when is_map(breakdown) and map_size(breakdown) > 0 do
    [:executed, :linked, :claimed, :uncovered]
    |> Enum.map(fn k -> {k, Map.get(breakdown, k, 0)} end)
    |> Enum.reject(fn {_, n} -> n == 0 end)
    |> Enum.map_join(" · ", fn {k, n} -> "#{n} #{String.upcase(to_string(k))}" end)
  end

  defp strength_summary_text(_), do: ""

  defp render_sync_checklist(triage) do
    checks = build_sync_checks(triage)
    failed_count = Enum.count(checks, &(not &1.passed?))
    degraded_count = Enum.count(checks, &(&1.passed? and Map.get(&1, :degraded?, false)))

    vacuous_count =
      Enum.count(checks, fn c ->
        c.passed? and Map.get(c, :vacuous?, false) and not Map.get(c, :degraded?, false)
      end)

    passed_count = length(checks) - failed_count - vacuous_count - degraded_count
    open_attr = if failed_count > 0 or degraded_count > 0, do: " open", else: ""

    summary_text =
      cond do
        failed_count > 0 ->
          "More details — #{failed_count} of #{length(checks)} checks need attention"

        degraded_count > 0 ->
          "More details — #{passed_count} passed · #{degraded_count} could not be checked (detector unavailable)"

        vacuous_count > 0 ->
          "More details — #{passed_count} passed · #{vacuous_count} nothing to verify"

        true ->
          "More details — what was checked (#{length(checks)} checks, all passed)"
      end

    ~s"""
    <details class="sync-checklist"#{open_attr}>
      <summary class="sync-checklist-summary">#{h(summary_text)}</summary>
      <ul class="sync-check-list">
        #{Enum.map_join(checks, "\n", &render_sync_check/1)}
      </ul>
      <p class="sync-checklist-footnote">Triangulation: every requirement should link to code (<code>realized_by</code>), be exercised by a tagged test, and reach a verification claim. Above is what was actually verified for this change set.</p>
    </details>
    """
  end

  @doc false
  def build_sync_checks(triage) do
    fbc = triage.findings_by_code
    detector_by_leg = Map.get(triage, :detector_unavailable_by_leg, %{})

    [
      %{
        leg: "Spec",
        leg_key: :spec_well_formed,
        label: "The spec files themselves are well-formed",
        codes:
          ~w(
            missing_meta_field
            missing_requirement_id
            missing_scenario_id
            verification_unknown_kind
            verification_kind_invalid
            verification_missing_target
            verification_missing_command
            scenario_unknown_cover
            scenario_cover_unknown
            overlap/duplicate_covers
            overlap/must_stem_collision
          ),
        detail: nil,
        vacuous?: triage.affected_subject_count == 0
      },
      %{
        leg: "Spec → Code",
        leg_key: :spec_to_code,
        label: "Every <code>realized_by</code> surface and verification target file actually exists",
        codes: ~w(surface_target_missing verification_target_missing verification_target_missing_file),
        detail: detail_count("MFA", triage.binding_count),
        vacuous?: triage.binding_count == 0 and triage.verification_count == 0
      },
      %{
        leg: "Spec → Code",
        leg_key: :spec_to_code,
        label: "Each verification target file references the requirement id it claims to cover",
        codes: ~w(verification_target_missing_reference),
        detail: nil,
        vacuous?: triage.verification_count == 0
      },
      %{
        leg: "Spec → Code",
        leg_key: :spec_to_code,
        label: "Each <code>realized_by</code> binding still matches the live MFA closure",
        codes: ~w(branch_guard_realization_drift branch_guard_dangling_binding),
        detail: detail_count("MFA", triage.binding_count),
        vacuous?: triage.binding_count == 0
      },
      %{
        leg: "Spec → Tests",
        leg_key: :spec_to_tests,
        label: "Every requirement is named by at least one verification entry",
        codes: ~w(requirement_without_verification verification_unknown_cover),
        detail: detail_count("requirement", triage.requirement_count),
        vacuous?: triage.requirement_count == 0
      },
      %{
        leg: "Spec → Tests",
        leg_key: :spec_to_tests,
        label: "Every <code>must</code> requirement under <code>tagged_tests</code> has a matching <code>@tag spec:</code>",
        codes: ~w(requirement_without_test_tag branch_guard_requirement_without_test_tag),
        detail: detail_count("requirement", triage.requirement_count),
        vacuous?: triage.requirement_count == 0
      },
      %{
        leg: "Spec → Tests",
        leg_key: :spec_to_tests,
        label: "Every binding closure is exercised by at least one tagged test",
        codes: ~w(branch_guard_untested_realization),
        detail: detail_count("MFA", triage.binding_count),
        vacuous?: triage.binding_count == 0
      },
      %{
        leg: "Tests → Coverage",
        leg_key: :tests_to_coverage,
        label: "Verifications that ran exited successfully",
        codes: ~w(verification_command_failed),
        detail: nil,
        vacuous?: triage.verification_count == 0
      },
      %{
        leg: "Code → Tests",
        leg_key: :tests_to_coverage,
        label: "Tagged tests actually exercise the subject they claim",
        codes: ~w(branch_guard_untethered_test branch_guard_underspecified_realization),
        detail: nil,
        vacuous?: triage.binding_count == 0
      },
      %{
        leg: "Coverage",
        leg_key: :tests_to_coverage,
        label: "Every requirement reaches its minimum coverage strength",
        codes: ~w(verification_strength_below_minimum),
        detail: strength_summary_text(triage.strength_breakdown),
        vacuous?: map_size(triage.strength_breakdown) == 0
      },
      %{
        leg: "Spec → Decisions",
        leg_key: :spec_to_decisions,
        label: "Every ADR referenced by a subject resolves to an existing decision file",
        codes: ~w(decision_reference_unknown subject_unknown_decision_reference),
        detail: adr_detail(triage),
        vacuous?: triage.adr_ref_count == 0
      },
      %{
        leg: "Decisions / governance",
        leg_key: :decisions_governance,
        label: "Every spec edit honors append-only governance and decision references",
        codes:
          ~w(
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
          ),
        detail: nil,
        vacuous?: triage.affected_subject_count == 0
      },
      %{
        leg: "Branch",
        leg_key: :branch,
        label: "Files changed in this PR have matching spec or decision updates",
        codes: ~w(branch_guard_missing_subject_update branch_guard_missing_decision_update branch_guard_unmapped_change),
        detail: nil,
        vacuous?: false
      }
    ]
    |> Enum.map(fn c ->
      count = Enum.sum(Enum.map(c.codes, &Map.get(fbc, &1, 0)))
      degraded_reasons = Map.get(detector_by_leg, c.leg_key, %{})

      Map.merge(c, %{
        count: count,
        passed?: count == 0,
        degraded?: count == 0 and map_size(degraded_reasons) > 0,
        degraded_reasons: degraded_reasons
      })
    end)
  end

  defp detail_count(_label, 0), do: nil
  defp detail_count(label, n), do: "#{n} #{label}#{maybe_s(n)} declared"

  defp adr_detail(%{adr_ref_count: 0}), do: nil
  defp adr_detail(%{adr_ref_count: n}), do: "#{n} reference#{maybe_s(n)}"
  defp adr_detail(_), do: nil

  defp render_sync_check(check) do
    degraded? = Map.get(check, :degraded?, false) and check.passed?
    vacuous? = Map.get(check, :vacuous?, false) and check.passed? and not degraded?

    {icon_class, icon} =
      cond do
        not check.passed? -> {"fail", "✗"}
        degraded? -> {"degraded", "?"}
        vacuous? -> {"vacuous", "—"}
        true -> {"ok", "✓"}
      end

    count_text =
      cond do
        not check.passed? ->
          ~s| <span class="sync-check-count">#{check.count} finding#{maybe_s(check.count)}</span>|

        degraded? ->
          reasons =
            check
            |> Map.get(:degraded_reasons, %{})
            |> Map.keys()
            |> Enum.sort()
            |> Enum.join(", ")

          ~s| <span class="sync-check-degraded-tag" title="Detector unavailable: #{h(reasons)}">detector unavailable</span>|

        vacuous? ->
          ~s| <span class="sync-check-vacuous-tag" title="No relevant claims on this PR — neither pass nor fail">nothing to verify</span>|

        true ->
          ""
      end

    detail_text =
      case check.detail do
        nil -> ""
        "" -> ""
        d -> ~s| <span class="sync-check-detail">#{h(d)}</span>|
      end

    ~s|<li class="sync-check sync-check-#{icon_class}"><span class="sync-check-icon" aria-hidden="true">#{icon}</span><span class="sync-check-leg">#{h(check.leg)}</span><span class="sync-check-label">#{check.label}</span>#{count_text}#{detail_text}</li>|
  end

  defp render_triage_subjects([]), do: ""

  defp render_triage_subjects(subjects) do
    [
      ~S|<ul class="triage-subjects">|,
      Enum.map(subjects, fn s ->
        badge =
          cond do
            s.findings_count == 0 ->
              ~S|<span class="badge badge-clean">clean</span>|

            Map.get(s.by_severity, "error", 0) > 0 ->
              ~s|<span class="badge badge-error">#{s.findings_count} #{maybe_plural(s.findings_count, "error")}</span>|

            Map.get(s.by_severity, "warning", 0) > 0 ->
              ~s|<span class="badge badge-warning">#{s.findings_count} #{maybe_plural(s.findings_count, "warning")}</span>|

            true ->
              ~s|<span class="badge badge-info">#{s.findings_count} #{maybe_plural(s.findings_count, "finding")}</span>|
          end

        ~s"""
        <li>
          <a class="triage-subject-link" href="#subject-#{slug(s.id)}">
            <code class="subject-id">#{h(s.id)}</code>
            #{badge}
          </a>
        </li>
        """
      end),
      ~S|</ul>|
    ]
  end

  defp maybe_plural(1, word), do: word
  defp maybe_plural(_, word), do: word <> "s"

  defp maybe_s(1), do: ""
  defp maybe_s(_), do: "s"

  defp render_findings_list([]), do: ""

  defp render_findings_list(findings) do
    [
      ~S"""
      <details class="findings-list" open>
        <summary>All findings</summary>
        <ul>
      """,
      Enum.map(findings, fn f ->
        sev = f["severity"] || ""

        ~s"""
            <li class="finding-item finding-#{h(sev)}">
              <span class="finding-severity"#{title_attr(tooltip(:severity, sev))}>#{h(sev)}</span>
              <span class="finding-code">#{h(f["code"])}</span>
              #{render_subject_link(f["subject_id"])}
              <span class="finding-message">#{h(f["message"])}</span>
            </li>
        """
      end),
      ~S"""
        </ul>
      </details>
      """
    ]
  end

  defp render_subject_link(nil), do: ""

  defp render_subject_link(subject_id) do
    ~s|<a class="finding-subject" href="#subject-#{slug(subject_id)}">#{h(subject_id)}</a>|
  end

  defp render_subjects([], _adrs), do: ""

  defp render_subjects(subjects, adrs) do
    [
      ~s|<section id="subjects" class="subjects" aria-label="Affected subjects">|,
      ~s|<h2 class="section-heading">Affected subjects (#{length(subjects)})</h2>|,
      Enum.map(subjects, &render_subject(&1, adrs)),
      ~S|</section>|
    ]
  end

  defp render_subject(subject, adrs) do
    EEx.eval_string(subject_template(),
      assigns: [s: subject, slug: slug(subject.id), adrs: adrs],
      trim: false
    )
  end

  # covers: specled.spec_review.per_subject_tabs
  # Each subject card exposes four tabs (Spec / Code / Coverage / Decisions)
  # that pivot from the prose statement to the supporting artifacts.
  #
  # covers: specled.spec_review.inline_finding_badges
  # Findings affecting the subject render as a badge on the card header in
  # addition to appearing in the top triage panel.
  defp subject_template do
    ~S"""
    <article class="subject" id="subject-<%= assigns[:slug] %>">
      <header class="subject-header">
        <p class="subject-statement"><%= SpecLedEx.Review.Html.h(assigns[:s].statement) %></p>
        <div class="subject-meta-row">
          <code class="subject-id"><%= SpecLedEx.Review.Html.h(assigns[:s].id) %></code>
          <%= if assigns[:s].file do %>
            <span class="subject-file"><%= SpecLedEx.Review.Html.h(assigns[:s].file) %></span>
          <% end %>
          <%= SpecLedEx.Review.Html.render_subject_change_badge(assigns[:s].spec_changes) %>
          <%= SpecLedEx.Review.Html.render_subject_finding_badges(assigns[:s].findings) %>
          <%= SpecLedEx.Review.Html.render_subject_binding_health(assigns[:s].bindings, assigns[:s].findings) %>
        </div>
      </header>
      <div class="tabs" role="tablist">
        <button class="tab active" role="tab" data-tab="spec-<%= assigns[:slug] %>">Spec</button>
        <button class="tab" role="tab" data-tab="code-<%= assigns[:slug] %>">Code (<%= length(assigns[:s].code_changes) %>)</button>
        <button class="tab" role="tab" data-tab="coverage-<%= assigns[:slug] %>">Coverage</button>
        <button class="tab" role="tab" data-tab="decisions-<%= assigns[:slug] %>">Decisions (<%= length(assigns[:s].decision_refs) %>)</button>
      </div>
      <div class="tab-panels">
        <section class="tab-panel active" id="spec-<%= assigns[:slug] %>" role="tabpanel">
          <%= SpecLedEx.Review.Html.render_spec_tab(assigns[:s]) %>
        </section>
        <section class="tab-panel" id="code-<%= assigns[:slug] %>" role="tabpanel">
          <%= SpecLedEx.Review.Html.render_code_tab(assigns[:s]) %>
        </section>
        <section class="tab-panel" id="coverage-<%= assigns[:slug] %>" role="tabpanel">
          <%= SpecLedEx.Review.Html.render_coverage_tab(assigns[:s]) %>
        </section>
        <section class="tab-panel" id="decisions-<%= assigns[:slug] %>" role="tabpanel">
          <%= SpecLedEx.Review.Html.render_decisions_tab(assigns[:s], assigns[:adrs]) %>
        </section>
      </div>
    </article>
    """
  end

  @doc false
  def render_subject_change_badge(%{base_existed?: false}),
    do:
      ~s|<span class="chip chip-new"#{title_attr(tooltip(:change, :new_subject))}>NEW SUBJECT</span>|

  def render_subject_change_badge(%{file_changed?: true}),
    do:
      ~s|<span class="chip chip-modified"#{title_attr(tooltip(:change, :spec_edited))}>SPEC EDITED</span>|

  def render_subject_change_badge(_), do: ""

  @doc false
  def render_subject_finding_badges([]), do: ""

  def render_subject_finding_badges(findings) do
    by_sev = Enum.group_by(findings, & &1["severity"])

    [
      Enum.map(["error", "warning", "info"], fn sev ->
        case Map.get(by_sev, sev) do
          nil -> ""
          [] -> ""
          list -> ~s|<span class="badge badge-#{sev}">#{length(list)} #{sev}</span>|
        end
      end)
    ]
  end

  # covers: specled.spec_review.inline_finding_badges
  # Surface per-subject binding health on the card header so triage does not
  # require a tab-dive into Coverage. Three states:
  #   * 0 bindings (no realized_by declared) — advisory chip
  #   * N bindings, K dangling             — error chip when dangling > 0
  #   * N bindings, all valid              — success chip when bindings > 0
  # Dangling counts come from the per-subject findings list, so the badge stays
  # in sync with the same `branch_guard_dangling_binding` finding rendered in
  # the triage panel.
  @doc false
  def render_subject_binding_health(bindings, findings) do
    total = count_bindings(bindings)
    dangling = count_dangling_findings(findings)

    cond do
      total == 0 ->
        ~s|<span class="badge badge-binding-health badge-binding-empty"#{title_attr(tooltip(:binding_health, :none))}>0 bindings (no realized_by declared)</span>|

      dangling > 0 ->
        ~s|<span class="badge badge-binding-health badge-binding-dangling"#{title_attr(tooltip(:binding_health, :dangling))}>#{total} #{maybe_plural(total, "binding")}, #{dangling} dangling</span>|

      true ->
        ~s|<span class="badge badge-binding-health badge-binding-valid"#{title_attr(tooltip(:binding_health, :valid))}>#{total} #{maybe_plural(total, "binding")}, all valid</span>|
    end
  end

  defp count_bindings(nil), do: 0
  defp count_bindings(bindings) when bindings == %{}, do: 0

  defp count_bindings(bindings) when is_map(bindings) do
    bindings
    |> Map.values()
    |> Enum.reduce(0, fn mfas, acc -> acc + length(List.wrap(mfas)) end)
  end

  defp count_bindings(_), do: 0

  defp count_dangling_findings(findings) when is_list(findings) do
    Enum.count(findings, fn f ->
      Map.get(f, "code") == "branch_guard_dangling_binding" or
        Map.get(f, :code) == "branch_guard_dangling_binding"
    end)
  end

  defp count_dangling_findings(_), do: 0

  @doc false
  def render_spec_tab(s) do
    req_status = id_status_lookup(s.spec_changes.requirements)
    scenario_status = id_status_lookup(s.spec_changes.scenarios)
    base_existed? = Map.get(s.spec_changes, :base_existed?, true)

    [
      render_spec_change_callout(s.spec_changes, base_existed?),
      render_requirements(s.requirements, s.findings, req_status),
      render_removed_items("Removed requirements", s.spec_changes.requirements.removed),
      render_scenarios(s.scenarios, scenario_status),
      render_removed_items("Removed scenarios", s.spec_changes.scenarios.removed),
      render_spec_diff(s.spec_diff)
    ]
  end

  defp id_status_lookup(%{added: added, modified: modified}) do
    added_ids = Enum.map(added, &item_id/1) |> Enum.reject(&(&1 == ""))
    modified_ids = Enum.map(modified, &item_id/1) |> Enum.reject(&(&1 == ""))

    added_ids
    |> Map.new(&{&1, :new})
    |> Map.merge(Map.new(modified_ids, &{&1, :modified}))
  end

  defp id_status_lookup(_), do: %{}

  defp item_id(item) do
    cond do
      is_struct(item) -> to_string(Map.get(item, :id) || "")
      is_map(item) and Map.has_key?(item, :id) -> to_string(item.id)
      is_map(item) and Map.has_key?(item, "id") -> to_string(item["id"])
      true -> ""
    end
  end

  defp render_spec_change_callout(_changes, false) do
    ~S"""
    <div class="spec-change-callout spec-change-new-subject">
      <strong>NEW SUBJECT</strong> — this spec file did not exist on the base ref.
    </div>
    """
  end

  defp render_spec_change_callout(changes, true) do
    counts = [
      {length(changes.requirements.added) + length(changes.scenarios.added), "added"},
      {length(changes.requirements.modified) + length(changes.scenarios.modified), "modified"},
      {length(changes.requirements.removed) + length(changes.scenarios.removed), "removed"}
    ]

    if Enum.all?(counts, fn {n, _} -> n == 0 end) do
      ""
    else
      summary =
        counts
        |> Enum.reject(fn {n, _} -> n == 0 end)
        |> Enum.map_join(" · ", fn {n, label} -> "#{n} #{label}" end)

      ~s"""
      <div class="spec-change-callout">
        <strong>Changes in this PR:</strong> #{summary}
      </div>
      """
    end
  end

  defp render_requirements([], _, _), do: ""

  defp render_requirements(requirements, findings, status_lookup) do
    findings_by_req = group_findings_by_requirement(findings)

    {changed, unchanged} =
      Enum.split_with(requirements, fn req ->
        id = field(req, :id) || ""
        Map.get(status_lookup, id, :unchanged) != :unchanged
      end)

    render_one = fn req ->
      id = field(req, :id) || ""
      statement = field(req, :statement) || ""
      priority = field(req, :priority) || ""
      stability = field(req, :stability) || ""
      req_findings = Map.get(findings_by_req, id, [])
      status = Map.get(status_lookup, id, :unchanged)

      ~s"""
      <li class="requirement requirement-#{status}">
        <div class="requirement-header">
          #{render_change_chip(status)}
          <code class="requirement-id">#{h(id)}</code>
          <span class="pill pill-priority pill-priority-#{h(priority)}"#{title_attr(tooltip(:priority, priority))}>#{h(priority)}</span>
          <span class="pill pill-neutral"#{title_attr(tooltip(:stability, stability))}>#{h(stability)}</span>
          #{render_requirement_finding_badge(req_findings)}
        </div>
        <p class="requirement-statement">#{h(statement)}</p>
      </li>
      """
    end

    [
      ~s|<h4 class="tab-heading">Requirements (#{length(requirements)})</h4>|,
      render_changed_then_unchanged("requirement", changed, unchanged, render_one)
    ]
  end

  # Default-shows the changed (NEW/MODIFIED) items; tucks unchanged items
  # behind a "Show N unchanged …" disclosure so the Spec tab focuses on
  # what's actually moving in this PR. When nothing changed, the toggle
  # is the only thing visible — clicking it reveals the full list.
  defp render_changed_then_unchanged(_singular, [], [], _renderer), do: ""

  defp render_changed_then_unchanged(_singular, changed, [], renderer) do
    [
      ~s|<ul class="#{change_list_class(changed)}">|,
      Enum.map(changed, renderer),
      ~S|</ul>|
    ]
  end

  defp render_changed_then_unchanged(singular, [], unchanged, renderer) do
    n = length(unchanged)

    [
      ~s|<details class="unchanged-disclosure">|,
      ~s|<summary class="unchanged-summary">Show #{n} unchanged #{singular}#{maybe_s(n)}</summary>|,
      ~s|<ul class="#{change_list_class(unchanged)}">|,
      Enum.map(unchanged, renderer),
      ~S|</ul>|,
      ~S|</details>|
    ]
  end

  defp render_changed_then_unchanged(singular, changed, unchanged, renderer) do
    n = length(unchanged)

    [
      ~s|<ul class="#{change_list_class(changed)}">|,
      Enum.map(changed, renderer),
      ~S|</ul>|,
      ~s|<details class="unchanged-disclosure">|,
      ~s|<summary class="unchanged-summary">Show #{n} unchanged #{singular}#{maybe_s(n)}</summary>|,
      ~s|<ul class="#{change_list_class(unchanged)}">|,
      Enum.map(unchanged, renderer),
      ~S|</ul>|,
      ~S|</details>|
    ]
  end

  # Pick the right CSS class so the disclosure-internal list matches the
  # outer list's spacing and dividers.
  defp change_list_class(items) do
    case items do
      [] -> "requirement-list"
      [first | _] ->
        cond do
          # Heuristic: scenario items have :given/:when/:then structure;
          # requirements have :statement/:priority. Cheapest probe is the
          # presence of :statement at the top level.
          field(first, :statement) -> "requirement-list"
          true -> "scenario-list"
        end
    end
  end

  defp render_change_chip(:new),
    do: ~s|<span class="chip chip-new"#{title_attr(tooltip(:change, :new))}>NEW</span>|

  defp render_change_chip(:modified),
    do: ~s|<span class="chip chip-modified"#{title_attr(tooltip(:change, :modified))}>MODIFIED</span>|

  defp render_change_chip(_), do: ""

  defp render_removed_items(_label, []), do: ""

  defp render_removed_items(label, items) do
    [
      ~s|<h4 class="tab-heading tab-heading-removed">#{h(label)} (#{length(items)})</h4>|,
      ~S|<ul class="removed-list">|,
      Enum.map(items, fn item ->
        id = item_id(item)
        statement = field(item, :statement) || field(item, :id) || ""

        ~s"""
        <li class="removed-item">
          <div class="removed-header">
            <span class="chip chip-removed"#{title_attr(tooltip(:change, :removed))}>REMOVED</span>
            <code class="requirement-id">#{h(id)}</code>
          </div>
          <p class="removed-statement">#{h(statement)}</p>
        </li>
        """
      end),
      ~S|</ul>|
    ]
  end

  defp render_requirement_finding_badge([]), do: ""

  defp render_requirement_finding_badge(findings) do
    severities = findings |> Enum.map(& &1["severity"]) |> Enum.uniq()
    most_severe = Enum.find(["error", "warning", "info"], &(&1 in severities)) || "warning"
    ~s|<span class="badge badge-#{most_severe}">#{length(findings)} finding</span>|
  end

  defp group_findings_by_requirement(findings) do
    Enum.reduce(findings, %{}, fn f, acc ->
      message = f["message"] || ""

      case Regex.run(~r/[a-z0-9][a-z0-9._-]+/, message) do
        [token] -> Map.update(acc, token, [f], &[f | &1])
        _ -> acc
      end
    end)
  end

  defp render_scenarios([], _), do: ""

  defp render_scenarios(scenarios, status_lookup) do
    {changed, unchanged} =
      Enum.split_with(scenarios, fn sc ->
        id = field(sc, :id) || ""
        Map.get(status_lookup, id, :unchanged) != :unchanged
      end)

    render_one = fn sc ->
      id = field(sc, :id) || ""
      given = field(sc, :given) || []
      when_ = field(sc, :when) || []
      then_ = field(sc, :then) || []
      covers = field(sc, :covers) || []
      status = Map.get(status_lookup, id, :unchanged)

      ~s"""
      <li class="scenario scenario-#{status}">
        <div class="scenario-header">
          #{render_change_chip(status)}
          <code class="scenario-id">#{h(id)}</code>
          #{Enum.map_join(covers, " ", fn c -> ~s|<span class="pill pill-cover">#{h(c)}</span>| end)}
        </div>
        <div class="gherkin">
          #{render_gherkin_section("given", given)}
          #{render_gherkin_section("when", when_)}
          #{render_gherkin_section("then", then_)}
        </div>
      </li>
      """
    end

    [
      ~s|<h4 class="tab-heading">Scenarios (#{length(scenarios)})</h4>|,
      render_changed_then_unchanged("scenario", changed, unchanged, render_one)
    ]
  end

  defp render_gherkin_section(_, []), do: ""

  defp render_gherkin_section(label, items) do
    ~s"""
    <div class="gherkin-row">
      <span class="gherkin-label">#{h(label)}</span>
      <ul class="gherkin-items">
    #{Enum.map_join(items, "\n", fn item -> ~s|    <li>#{h(item)}</li>| end)}
      </ul>
    </div>
    """
  end

  defp render_spec_diff(nil), do: ""

  defp render_spec_diff(%{file: file, lines: lines}) do
    [
      ~s|<h4 class="tab-heading">Spec file changes</h4>|,
      ~s|<div class="filename"><code>#{h(file)}</code></div>|,
      render_diff_block(lines, language_for(file))
    ]
  end

  @doc false
  def render_code_tab(%{code_changes: []}) do
    ~S|<p class="empty-tab">No code files in this change set map to this subject.</p>|
  end

  def render_code_tab(%{code_changes: changes, id: id}) do
    anchor_prefix = "code-" <> slug(id)
    paths = Enum.map(changes, & &1.file)
    tree = build_path_tree(paths)

    diff_blocks =
      Enum.map(changes, fn %{file: file, lines: lines} ->
        anchor = anchor_prefix <> "-" <> slug(file)

        ~s"""
        <details class="code-change" id="#{anchor}" open>
          <summary class="filename"><code>#{h(file)}</code></summary>
          #{IO.iodata_to_binary(render_diff_block(lines, language_for(file)))}
        </details>
        """
      end)

    render_files_section(tree, anchor_prefix, "Files (#{length(paths)})", diff_blocks)
  end

  @doc false
  def render_coverage_tab(s) do
    [
      render_coverage_help_link(),
      render_requirements_coverage(s.requirements, s.claims_by_req),
      render_bindings_section(s.bindings)
    ]
  end

  # Per-tab pointer back to the single page-level help disclosure. The full
  # legend used to re-render inside every Coverage tab; now there's exactly
  # one copy near the triage panel and each tab links to it.
  defp render_coverage_help_link do
    ~S|<p class="coverage-help-link"><a href="#coverage-help">How is requirement coverage computed?</a></p>|
  end

  # covers: specled.spec_review.triage_panel
  # The legend used to live inside every subject Coverage tab. It now renders
  # once near the page-level triage panel; per-tab links point here.
  defp render_coverage_help_disclosure do
    ~S"""
    <details class="coverage-help" id="coverage-help">
      <summary class="coverage-help-summary"><span aria-hidden="true">ℹ</span> How is requirement coverage computed?</summary>
      <div class="coverage-help-body">
        <p>Each requirement is verified by one or more <code>spec-verification</code> entries that name it in their <code>covers:</code> list. The verifier inspects each entry and reports the <strong>strongest evidence</strong> it could find for the requirement.</p>
        <dl class="coverage-help-tiers">
          <dt><span class="strength-badge strength-executed">EXECUTED</span></dt>
          <dd>A <code>kind: command</code> entry with <code>execute: true</code> ran and exited 0; or a <code>kind: tagged_tests</code> entry executed its matching test successfully. Requires <code>mix spec.check --run-commands</code> (or <code>mix spec.review --run-commands</code>).</dd>
          <dt><span class="strength-badge strength-linked">LINKED</span></dt>
          <dd>For a <em>file-kind</em> verification (<code>source_file</code>, <code>test_file</code>, <code>guide_file</code>, …) the target file exists <em>and</em> its content references the requirement id (typically a <code># covers:</code> comment or a literal mention). For <code>tagged_tests</code>, a test in the suite carries <code>@tag spec: "&lt;requirement_id&gt;"</code>.</dd>
          <dt><span class="strength-badge strength-claimed">CLAIMED</span></dt>
          <dd>The verification entry names the requirement in its <code>covers:</code> list. A textual claim only — nothing else has been checked yet.</dd>
          <dt><span class="strength-badge strength-uncovered">UNCOVERED</span></dt>
          <dd>No verification entry covers this requirement at all. Add one to <code>spec-verification</code>.</dd>
        </dl>
        <p><strong>Tightening the floor.</strong> Pass <code>--min-strength linked</code> (or <code>executed</code>) to <code>mix spec.check</code> to require every claim reach that tier or fail. Set <code>verification_minimum_strength: linked</code> in a subject's <code>spec-meta</code> to bake that floor into the spec itself.</p>
        <p><strong>Priority</strong> (<code>must</code> / <code>should</code> / <code>may</code>) is the requirement author's RFC-2119 intent. <strong>Stability</strong> (<code>stable</code> / <code>evolving</code>) communicates whether the wording is settled or still being tightened. Hover any chip on this page for a one-line definition.</p>
      </div>
    </details>
    """
  end

  defp render_requirements_coverage([], _), do: ""

  defp render_requirements_coverage(requirements, claims_by_req) do
    rows =
      Enum.map(requirements, fn req ->
        id = field(req, :id) || ""
        statement = field(req, :statement) || ""
        priority = field(req, :priority) || ""
        claims = Map.get(claims_by_req, id, [])
        best_strength = best_claim_strength(claims)
        meets_minimum? = Enum.all?(claims, &(&1["meets_minimum"] != false))

        ~s"""
        <li class="cov-req cov-req-#{best_strength}">
          <div class="cov-req-header">
            <code class="requirement-id">#{h(id)}</code>
            <span class="pill pill-priority pill-priority-#{h(priority)}"#{title_attr(tooltip(:priority, priority))}>#{h(priority)}</span>
            #{render_strength_badge(best_strength, claims, meets_minimum?)}
          </div>
          <p class="cov-req-statement">#{h(statement)}</p>
          #{render_covering_claims(claims)}
        </li>
        """
      end)

    [
      ~s|<h4 class="tab-heading">Requirement coverage (#{length(requirements)})</h4>|,
      render_strength_legend(),
      ~S|<ul class="cov-req-list">|,
      rows,
      ~S|</ul>|
    ]
  end

  defp best_claim_strength([]), do: :uncovered

  defp best_claim_strength(claims) do
    strengths = Enum.map(claims, & &1["strength"])

    cond do
      "executed" in strengths -> :executed
      "linked" in strengths -> :linked
      "claimed" in strengths -> :claimed
      true -> :uncovered
    end
  end

  defp render_strength_badge(:uncovered, _claims, _meets) do
    ~s|<span class="strength-badge strength-uncovered"#{title_attr(tooltip(:strength, "uncovered"))}>UNCOVERED</span>|
  end

  defp render_strength_badge(strength, claims, meets) do
    str = to_string(strength)
    label = String.upcase(str)
    suffix = if length(claims) > 1, do: " · #{length(claims)} claims", else: ""

    warn =
      if meets,
        do: "",
        else:
          ~S| <span class="strength-warn" title="Below the required strength for this requirement (see verification_minimum_strength or --min-strength)">⚠</span>|

    ~s|<span class="strength-badge strength-#{str}"#{title_attr(tooltip(:strength, str))}>#{label}#{suffix}</span>#{warn}|
  end

  defp render_strength_legend do
    ~s"""
    <div class="strength-legend" aria-label="Strength legend">
      <span class="strength-badge strength-executed"#{title_attr(tooltip(:strength, "executed"))}>EXECUTED</span>
      <span class="strength-legend-arrow">›</span>
      <span class="strength-badge strength-linked"#{title_attr(tooltip(:strength, "linked"))}>LINKED</span>
      <span class="strength-legend-arrow">›</span>
      <span class="strength-badge strength-claimed"#{title_attr(tooltip(:strength, "claimed"))}>CLAIMED</span>
      <span class="strength-legend-arrow">›</span>
      <span class="strength-badge strength-uncovered"#{title_attr(tooltip(:strength, "uncovered"))}>UNCOVERED</span>
      <span class="strength-legend-note">strongest evidence wins per requirement</span>
    </div>
    """
  end

  defp render_covering_claims([]), do: ""

  defp render_covering_claims(claims) do
    [
      ~S|<ul class="claim-list">|,
      Enum.map(claims, fn c ->
        kind = c["kind"] || ""
        target = c["target"] || ""
        strength = c["strength"] || "claimed"

        ~s"""
        <li class="claim">
          <span class="pill pill-neutral"#{title_attr(tooltip(:verification_kind, kind))}>#{h(kind)}</span>
          <code class="claim-target">#{h(target)}</code>
          <span class="strength-badge strength-#{strength}"#{title_attr(tooltip(:strength, strength))}>#{String.upcase(strength)}</span>
        </li>
        """
      end),
      ~S|</ul>|
    ]
  end

  defp render_bindings_section(bindings) when bindings == %{} or is_nil(bindings), do: ""

  defp render_bindings_section(bindings) do
    [
      ~s|<h4 class="tab-heading">Bindings (realized_by)</h4>|,
      ~S|<dl class="bindings">|,
      Enum.map(bindings, fn {tier, mfas} ->
        mfas = List.wrap(mfas)

        [
          ~s|<dt>#{h(to_string(tier))}</dt>|,
          ~s|<dd><ul class="mfa-list">|,
          Enum.map(mfas, fn mfa -> ~s|<li><code>#{h(mfa)}</code></li>| end),
          ~S|</ul></dd>|
        ]
      end),
      ~S|</dl>|
    ]
  end

  # Page-level aggregator. Renders a single "Raw verification (all subjects)"
  # disclosure containing every spec-verification entry across affected
  # subjects, grouped by subject. The per-subject Coverage tab no longer
  # repeats this block — power-user noise is consolidated to one place.
  defp render_raw_verification_all(subjects) do
    grouped =
      subjects
      |> Enum.map(fn s -> {s, List.wrap(s.verification)} end)
      |> Enum.reject(fn {_s, list} -> list == [] end)

    case grouped do
      [] ->
        ""

      _ ->
        total = Enum.reduce(grouped, 0, fn {_s, list}, acc -> acc + length(list) end)

        [
          ~s|<section id="raw-verification" class="raw-verification-all" aria-label="Raw verification across subjects">|,
          ~s|<details class="raw-verification">|,
          ~s|<summary class="raw-verification-summary">Raw spec-verification (all subjects · #{total} entr#{if total == 1, do: "y", else: "ies"})</summary>|,
          ~S|<p class="raw-verification-explainer">The author's declarations as written in each subject's spec file. The per-requirement Coverage views above are computed from these entries.</p>|,
          Enum.map(grouped, fn {s, list} -> render_raw_verification_subject(s, list) end),
          ~S|</details>|,
          ~S|</section>|
        ]
    end
  end

  defp render_raw_verification_subject(subject, list) do
    [
      ~s|<div class="raw-verification-subject">|,
      ~s|<h4 class="raw-verification-subject-heading"><a href="#subject-#{slug(subject.id)}"><code>#{h(subject.id)}</code></a> <span class="raw-verification-subject-count">(#{length(list)})</span></h4>|,
      ~S|<ul class="verification-list">|,
      Enum.map(list, &render_verification_entry/1),
      ~S|</ul>|,
      ~S|</div>|
    ]
  end

  defp render_verification_entry(v) do
    kind = field(v, :kind) || ""
    target = field(v, :target) || ""
    covers = field(v, :covers) || []
    execute = field(v, :execute) || false

    ~s"""
    <li class="verification">
      <div class="verification-header">
        <span class="pill pill-neutral"#{title_attr(tooltip(:verification_kind, kind))}>#{h(kind)}</span>
        <code class="verification-target">#{h(target)}</code>
        #{if execute, do: ~s|<span class="pill pill-success"#{title_attr(tooltip(:execute, true))}>executes</span>|, else: ~s|<span class="pill pill-muted"#{title_attr(tooltip(:execute, false))}>declared</span>|}
      </div>
      <div class="verification-covers">
        #{Enum.map_join(covers, " ", fn c -> ~s|<span class="pill pill-cover">#{h(c)}</span>| end)}
      </div>
    </li>
    """
  end

  @doc false
  def render_decisions_tab(%{decision_refs: []}, _adrs) do
    ~S|<p class="empty-tab">No ADRs referenced by this subject.</p>|
  end

  def render_decisions_tab(%{decision_refs: refs}, adrs) do
    [
      ~s|<h4 class="tab-heading">ADRs referenced (#{length(refs)})</h4>|,
      ~S|<div class="adr-list">|,
      Enum.map(refs, fn id -> render_adr_disclosure(id, Map.get(adrs || %{}, id)) end),
      ~S|</div>|
    ]
  end

  defp render_adr_disclosure(id, nil) do
    ~s"""
    <details class="adr">
      <summary class="adr-summary">
        <code class="adr-id">#{h(id)}</code>
        <span class="adr-title-missing">unknown ADR (not found in index)</span>
      </summary>
    </details>
    """
  end

  defp render_adr_disclosure(_id, adr) do
    status_pill =
      if adr.status, do: ~s|<span class="pill pill-neutral">#{h(adr.status)}</span>|, else: ""

    date_chip =
      if adr.date, do: ~s|<span class="adr-date">#{h(adr.date)}</span>|, else: ""

    change_type_pill =
      if adr.change_type,
        do: ~s|<span class="pill pill-cover">#{h(adr.change_type)}</span>|,
        else: ""

    change_chip =
      case Map.get(adr, :change_status) do
        :new -> ~S|<span class="chip chip-new">NEW</span>|
        :modified -> ~S|<span class="chip chip-modified">MODIFIED</span>|
        :removed -> ~S|<span class="chip chip-removed">REMOVED</span>|
        _ -> ""
      end

    ~s"""
    <details class="adr adr-#{Map.get(adr, :change_status, :unchanged)}">
      <summary class="adr-summary">
        #{change_chip}
        <code class="adr-id">#{h(adr.id)}</code>
        <span class="adr-title">#{h(adr.title)}</span>
        #{status_pill}#{change_type_pill}#{date_chip}
      </summary>
      <div class="adr-body-wrap">
        <div class="markdown-body">#{render_markdown(adr.body_text)}</div>
        #{if adr.file, do: ~s|<div class="adr-source"><code>#{h(adr.file)}</code></div>|, else: ""}
      </div>
    </details>
    """
  end

  # Renders a markdown string as HTML using Earmark with safe defaults.
  # The leading H1 (the ADR title) is stripped because the title already
  # appears in the disclosure summary, so duplicating it is noise.
  defp render_markdown(text) when is_binary(text) do
    stripped = strip_leading_h1(text)

    case Earmark.as_html(stripped, escape: true, compact_output: false) do
      {:ok, html, _} -> html
      {:error, html, _messages} -> html
    end
  end

  defp render_markdown(_), do: ""

  defp strip_leading_h1(text) do
    text
    |> String.split("\n", parts: 2)
    |> case do
      ["# " <> _, rest] -> String.trim_leading(rest, "\n")
      [first, rest] -> first <> "\n" <> rest
      [single] -> single
    end
  end

  defp render_decisions_changed([], _adrs_by_id) do
    ~S"""
    <section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">
      <h2 class="section-heading">Decisions changed (0)</h2>
      <p class="empty-tab">No ADR files changed in this change set.</p>
    </section>
    """
  end

  defp render_decisions_changed(decisions, adrs_by_id) do
    [
      ~s|<section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">|,
      ~s|<h2 class="section-heading">Decisions changed (#{length(decisions)})</h2>|,
      ~S|<div class="decision-changed-list">|,
      Enum.map(decisions, &render_changed_decision(&1, adrs_by_id || %{})),
      ~S|</div>|,
      ~S|</section>|
    ]
  end

  defp render_changed_decision(d, adrs_by_id) do
    case Map.get(adrs_by_id, d.id) do
      nil -> render_changed_decision_minimal(d)
      adr -> render_changed_decision_full(d, adr)
    end
  end

  defp render_changed_decision_minimal(d) do
    anchor = "adr-" <> slug(d.id || d.file)

    ~s"""
    <details class="adr" id="#{anchor}">
      <summary class="adr-summary">
        <code class="adr-id">#{h(d.id || d.file)}</code>
        <span class="adr-title-missing">decision changed but no parsed ADR available</span>
        #{render_decision_status_pill(d.status)}
        #{render_decision_change_type_pill(d.change_type)}
      </summary>
      #{render_decision_affects_block(d.affects)}
    </details>
    """
  end

  defp render_changed_decision_full(d, adr) do
    change_chip =
      case Map.get(adr, :change_status) do
        :new -> ~S|<span class="chip chip-new">NEW</span>|
        :modified -> ~S|<span class="chip chip-modified">MODIFIED</span>|
        :removed -> ~S|<span class="chip chip-removed">REMOVED</span>|
        _ -> ""
      end

    date_chip =
      if adr.date, do: ~s|<span class="adr-date">#{h(adr.date)}</span>|, else: ""

    anchor = "adr-" <> slug(adr.id || d.file)

    ~s"""
    <details class="adr adr-#{Map.get(adr, :change_status, :unchanged)}" id="#{anchor}" open>
      <summary class="adr-summary">
        #{change_chip}
        <code class="adr-id">#{h(adr.id)}</code>
        <span class="adr-title">#{h(adr.title)}</span>
        #{render_decision_status_pill(adr.status)}
        #{render_decision_change_type_pill(d.change_type || adr.change_type)}
        #{date_chip}
      </summary>
      <div class="adr-body-wrap">
        #{render_decision_affects_block(d.affects)}
        <div class="markdown-body">#{render_markdown(adr.body_text)}</div>
        #{if adr.file, do: ~s|<div class="adr-source"><code>#{h(adr.file)}</code></div>|, else: ""}
      </div>
    </details>
    """
  end

  defp render_decision_status_pill(nil), do: ""

  defp render_decision_status_pill(status) do
    class = decision_status_pill_class(status)
    ~s|<span class="pill #{class}"#{title_attr(decision_status_tooltip(status))}>#{h(status)}</span>|
  end

  defp decision_status_pill_class(status) do
    case String.downcase(to_string(status)) do
      "accepted" -> "pill-status-accepted"
      "proposed" -> "pill-status-proposed"
      "deprecated" -> "pill-status-deprecated"
      "superseded" -> "pill-status-superseded"
      "rejected" -> "pill-status-rejected"
      "draft" -> "pill-status-draft"
      _ -> "pill-neutral"
    end
  end

  defp decision_status_tooltip(status) do
    case String.downcase(to_string(status)) do
      "accepted" -> "The decision is in force."
      "proposed" -> "Drafted but not yet ratified."
      "deprecated" -> "No longer recommended; may still apply to existing code."
      "superseded" -> "Replaced by a newer decision (see superseded_by)."
      "rejected" -> "Considered and explicitly not adopted."
      "draft" -> "Work-in-progress; expect changes before acceptance."
      _ -> ""
    end
  end

  defp render_decision_change_type_pill(nil), do: ""

  defp render_decision_change_type_pill(ct),
    do: ~s|<span class="pill pill-cover">#{h(ct)}</span>|

  defp render_decision_affects_block([]), do: ""

  defp render_decision_affects_block(affects) do
    links =
      Enum.map_join(affects, "", fn id ->
        ~s|<a class="decision-affects-link" href="#subject-#{slug(id)}"><code>#{h(id)}</code></a>|
      end)

    ~s|<div class="decision-affects"><span class="decision-affects-label">Affects:</span> #{links}</div>|
  end

  defp render_unmapped([], breakdown) do
    [
      ~s|<section id="misc" class="misc" aria-label="Outside the spec system">|,
      ~s|<h2 class="section-heading">Outside the spec system (0)</h2>|,
      render_misc_breakdown(breakdown),
      ~s|<p class="empty-tab">All file changes in this change set map to a spec subject or a policy file.</p>|,
      ~S|</section>|
    ]
  end

  defp render_unmapped(changes, breakdown) do
    paths = Enum.map(changes, & &1.file)

    diff_blocks =
      Enum.map(changes, fn %{file: file, lines: lines} ->
        anchor = "misc-" <> slug(file)

        ~s"""
        <details class="code-change" id="#{anchor}" open>
          <summary class="filename"><code>#{h(file)}</code></summary>
          #{IO.iodata_to_binary(render_diff_block(lines, language_for(file)))}
        </details>
        """
      end)

    [
      ~s|<section id="misc" class="misc" aria-label="Outside the spec system">|,
      ~s|<h2 class="section-heading">Outside the spec system (#{length(changes)})</h2>|,
      render_misc_breakdown(breakdown),
      ~S|<p class="misc-explainer">These files changed but do not map to any spec subject. Triangulation does not apply here — review the diff directly.</p>|,
      render_misc_files(paths, diff_blocks),
      ~S|</section>|
    ]
  end

  # When there are few unmapped files (<= 3), the file-tree rail is more
  # chrome than signal — render the diff blocks flat. Above that threshold,
  # fall back to the standard tree+files layout.
  @misc_flat_threshold 3

  defp render_misc_files(paths, diff_blocks) when length(paths) <= @misc_flat_threshold do
    ~s"""
    <div class="files-section files-section-flat">
      <div class="files-list">
        #{IO.iodata_to_binary(diff_blocks)}
      </div>
    </div>
    """
  end

  defp render_misc_files(paths, diff_blocks) do
    tree = build_path_tree(paths)
    render_files_section(tree, "misc", "Files (#{length(paths)})", diff_blocks)
  end

  # Header breakdown so a reviewer can see all N changed files accounted
  # for: how many landed in subjects (visible in their Code tabs above),
  # how many are spec/decision policy files (visible in their Spec tabs
  # or in "Decisions changed"), and how many are listed below.
  defp render_misc_breakdown(nil), do: ""

  defp render_misc_breakdown(%{total: 0}), do: ""

  defp render_misc_breakdown(%{total: total, mapped: mapped, policy: policy, unmapped: unmapped}) do
    ~s"""
    <div class="misc-breakdown" role="note">
      <span class="misc-breakdown-label">Of #{total} changed file#{maybe_s(total)} in this PR:</span>
      <ul class="misc-breakdown-list">
        #{misc_breakdown_row(mapped, "map to a spec subject", "see the subject's Code tab above", "#subjects")}
        #{misc_breakdown_row(policy, "are spec/decision files", "see the Spec tab on the affected subject(s) or the Decisions changed section", "#decisions-changed")}
        #{misc_breakdown_row(unmapped, "have no spec mapping", "listed below", nil)}
      </ul>
    </div>
    """
  end

  defp misc_breakdown_row(0, _label, _detail, _anchor), do: ""

  defp misc_breakdown_row(n, label, detail, nil) do
    ~s|<li><strong>#{n}</strong> #{h(label)} <span class="misc-breakdown-detail">— #{h(detail)}</span></li>|
  end

  defp misc_breakdown_row(n, label, detail, anchor) do
    ~s|<li><strong>#{n}</strong> #{h(label)} <span class="misc-breakdown-detail">— <a href="#{anchor}">#{h(detail)}</a></span></li>|
  end

  @doc false
  def render_diff_stats(%{files_changed: files, additions: adds, deletions: dels}) do
    ~s|<span class="diffstat" title="#{files} file#{if files == 1, do: "", else: "s"} changed · +#{adds} −#{dels} lines"><span class="diffstat-files">#{files} file#{if files == 1, do: "", else: "s"}</span><span class="diffstat-add">+#{adds}</span><span class="diffstat-del">−#{dels}</span><span class="diffstat-bar" aria-hidden="true">#{render_diffstat_bar(adds, dels)}</span></span>|
  end

  def render_diff_stats(_), do: ""

  # 5-block bar: green for adds, red for dels, grey filler — like GitHub's PR list.
  defp render_diffstat_bar(adds, dels) do
    total = adds + dels
    {n_add, n_del} =
      if total == 0 do
        {0, 0}
      else
        a = round(adds * 5 / total)
        d = round(dels * 5 / total)
        # Force at least one block for non-zero side; cap total at 5.
        a = if adds > 0 and a == 0, do: 1, else: a
        d = if dels > 0 and d == 0, do: 1, else: d

        cond do
          a + d > 5 -> if a >= d, do: {5 - d, d}, else: {a, 5 - a}
          true -> {a, d}
        end
      end

    n_empty = 5 - n_add - n_del

    String.duplicate(~S|<span class="diffstat-block diffstat-block-add"></span>|, n_add) <>
      String.duplicate(~S|<span class="diffstat-block diffstat-block-del"></span>|, n_del) <>
      String.duplicate(~S|<span class="diffstat-block diffstat-block-empty"></span>|, n_empty)
  end

  defp render_files_view([], _stats) do
    ~S|<section class="files-view"><p class="empty-tab">No file changes in this change set.</p></section>|
  end

  defp render_files_view(all_changes, stats) do
    paths = Enum.map(all_changes, & &1.file)
    tree = build_path_tree(paths)

    diff_blocks =
      Enum.map(all_changes, fn %{file: file, lines: lines} ->
        anchor = "files-" <> slug(file)

        ~s"""
        <details class="code-change" id="#{anchor}" open>
          <summary class="filename"><code>#{h(file)}</code></summary>
          #{IO.iodata_to_binary(render_diff_block(lines, language_for(file)))}
        </details>
        """
      end)

    heading = "Files (#{length(paths)}) · +#{stats.additions} −#{stats.deletions}"

    [
      ~s|<section class="files-view" aria-label="All changed files">|,
      ~s|<h2 class="section-heading">All changed files (#{length(paths)})</h2>|,
      ~s|<p class="files-view-explainer">Every file in the diff against the base ref, with no spec-subject grouping. This is what you'd see in a typical PR review.</p>|,
      render_files_section(tree, "files", heading, diff_blocks),
      ~S|</section>|
    ]
  end

  # ----------------------------------------------------------------------
  # Path tree
  # ----------------------------------------------------------------------

  # Builds a nested map representing a folder/file tree from a list of paths.
  # Leaves are tagged {:file, full_path} for anchor linking.
  defp build_path_tree(paths) do
    Enum.reduce(paths, %{}, fn path, tree ->
      parts = path |> String.split("/") |> Enum.reject(&(&1 == ""))
      insert_path(tree, parts, path)
    end)
  end

  defp insert_path(tree, [leaf], full_path) do
    Map.put(tree, leaf, {:file, full_path})
  end

  defp insert_path(tree, [head | rest], full_path) do
    sub =
      case Map.get(tree, head) do
        nil -> %{}
        existing when is_map(existing) -> existing
        # Should not happen unless a path collides with a directory name;
        # treat as a fresh subtree.
        _ -> %{}
      end

    Map.put(tree, head, insert_path(sub, rest, full_path))
  end

  defp render_files_section(tree, anchor_prefix, heading, diff_blocks) do
    ~s"""
    <div class="files-section" data-tree-section>
      <div class="file-tree-rail" aria-hidden="false">
        <aside class="file-tree-panel" aria-label="File tree">
          <header class="file-tree-header">
            <span class="file-tree-title">#{h(heading)}</span>
            <button class="file-tree-close" type="button" aria-label="Hide file tree" data-tree-action="close">×</button>
          </header>
          <div class="file-tree-scroll">
            #{IO.iodata_to_binary(render_tree_nodes(tree, anchor_prefix))}
          </div>
        </aside>
        <button class="file-tree-handle" type="button" aria-label="Show file tree" data-tree-action="open">
          <span class="file-tree-handle-icon" aria-hidden="true">▸</span>
        </button>
      </div>
      <div class="files-list">
        #{IO.iodata_to_binary(diff_blocks)}
      </div>
    </div>
    """
  end

  defp render_tree_nodes(tree, anchor_prefix) do
    items =
      tree
      |> Enum.sort_by(fn {name, value} ->
        # Folders before files at the same level.
        case value do
          {:file, _} -> {1, name}
          _ -> {0, name}
        end
      end)
      |> Enum.map(fn
        {name, {:file, full_path}} ->
          anchor = anchor_prefix <> "-" <> slug(full_path)

          ~s"""
          <li class="tree-leaf">
            <a href="##{anchor}" data-tree-leaf><code>#{h(name)}</code></a>
          </li>
          """

        {name, sub_tree} when is_map(sub_tree) ->
          ~s"""
          <li class="tree-folder">
            <details open>
              <summary class="tree-folder-summary"><code>#{h(name)}/</code></summary>
              #{IO.iodata_to_binary(render_tree_nodes(sub_tree, anchor_prefix))}
            </details>
          </li>
          """
      end)

    [~S|<ul class="tree">|, items, ~S|</ul>|]
  end

  defp render_diff_block([], _lang) do
    ~S|<p class="empty-tab">(no diff content)</p>|
  end

  defp render_diff_block(lines, lang) do
    {rows, _state} =
      Enum.flat_map_reduce(lines, %{old: 0, new: 0}, fn entry, state ->
        render_diff_row(entry, state, lang)
      end)

    [~S|<div class="diff">|, rows, ~S|</div>|]
  end

  # File-header lines (`diff --git ...`, `--- a/...`, `+++ b/...`) are
  # noise once the filename is shown in the disclosure summary above.
  defp render_diff_row({:file_header, _text}, state, _lang), do: {[], state}

  defp render_diff_row({:hunk_header, text}, _state, _lang) do
    new_state = parse_hunk_header(text)

    row =
      ~s|<div class="diff-row diff-row-hunk"><span class="diff-lineno"></span><span class="diff-lineno"></span><span class="diff-marker"></span><span class="diff-content">#{h(text)}</span></div>|

    {[row], new_state}
  end

  defp render_diff_row({:add, text}, %{new: n} = state, lang) do
    new_no = n + 1
    content = strip_diff_marker(text, "+")

    row =
      ~s|<div class="diff-row diff-row-add"><span class="diff-lineno"></span><span class="diff-lineno diff-lineno-new">#{new_no}</span><span class="diff-marker">+</span>#{render_diff_content(content, lang)}</div>|

    {[row], %{state | new: new_no}}
  end

  defp render_diff_row({:del, text}, %{old: o} = state, lang) do
    old_no = o + 1
    content = strip_diff_marker(text, "-")

    row =
      ~s|<div class="diff-row diff-row-del"><span class="diff-lineno diff-lineno-old">#{old_no}</span><span class="diff-lineno"></span><span class="diff-marker">−</span>#{render_diff_content(content, lang)}</div>|

    {[row], %{state | old: old_no}}
  end

  defp render_diff_row({:ctx, text}, %{old: o, new: n} = state, lang) do
    old_no = o + 1
    new_no = n + 1
    content = strip_diff_marker(text, " ")

    row =
      ~s|<div class="diff-row diff-row-ctx"><span class="diff-lineno">#{old_no}</span><span class="diff-lineno">#{new_no}</span><span class="diff-marker"></span>#{render_diff_content(content, lang)}</div>|

    {[row], %{state | old: old_no, new: new_no}}
  end

  defp render_diff_content(content, nil),
    do: ~s|<span class="diff-content">#{h(content)}</span>|

  defp render_diff_content(content, lang),
    do: ~s|<code class="diff-content language-#{lang}">#{h(content)}</code>|

  # Maps a file path to a Prism language class. Returns nil for files
  # whose language we don't ship a lexer for; those render without
  # syntax highlighting.
  defp language_for(file) when is_binary(file) do
    case file |> Path.extname() |> String.downcase() do
      ".ex" -> "elixir"
      ".exs" -> "elixir"
      ".eex" -> "elixir"
      ".heex" -> "elixir"
      ".leex" -> "elixir"
      ".erl" -> "erlang"
      ".hrl" -> "erlang"
      ".json" -> "json"
      ".yaml" -> "yaml"
      ".yml" -> "yaml"
      ".md" -> "markdown"
      ".markdown" -> "markdown"
      ".css" -> "css"
      ".scss" -> "css"
      ".html" -> "markup"
      ".htm" -> "markup"
      ".xml" -> "markup"
      ".svg" -> "markup"
      ".sh" -> "bash"
      ".bash" -> "bash"
      ".diff" -> "diff"
      ".patch" -> "diff"
      _ -> nil
    end
  end

  defp language_for(_), do: nil

  defp strip_diff_marker(<<marker::utf8, rest::binary>>, expected) do
    if <<marker::utf8>> == expected, do: rest, else: <<marker::utf8>> <> rest
  end

  defp strip_diff_marker(text, _), do: text

  defp parse_hunk_header(text) do
    case Regex.run(~r/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, text) do
      [_, old_start, new_start] ->
        %{old: String.to_integer(old_start) - 1, new: String.to_integer(new_start) - 1}

      _ ->
        %{old: 0, new: 0}
    end
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  @doc false
  def h(nil), do: ""
  def h(value) when is_binary(value), do: html_escape(value)
  def h(value), do: value |> to_string() |> html_escape()

  # Tooltip text by (category, value). Returns "" when nothing useful applies
  # so the caller can render `title="..."` unconditionally.
  defp tooltip(:strength, "executed"),
    do: "Command verification ran and exited 0 (requires --run-commands)"

  defp tooltip(:strength, "linked"),
    do:
      "File-kind verification: target file exists and contains the requirement id; or tagged_tests: a test in the suite carries @tag spec for the requirement"

  defp tooltip(:strength, "claimed"),
    do:
      "A spec-verification entry names the requirement in its covers: list. Textual claim only — nothing else has been checked."

  defp tooltip(:strength, "uncovered"),
    do: "No spec-verification entry covers this requirement."

  defp tooltip(:priority, "must"), do: "Required (RFC 2119)"

  defp tooltip(:priority, "should"),
    do: "Recommended; can be skipped with explicit justification (RFC 2119)"

  defp tooltip(:priority, "may"), do: "Optional (RFC 2119)"

  defp tooltip(:stability, "stable"), do: "Wording is settled; unlikely to change shape"

  defp tooltip(:stability, "evolving"),
    do: "Wording is being tightened or restructured; expect churn"

  defp tooltip(:verification_kind, "command"),
    do: "Runs an arbitrary command. Reaches EXECUTED when the command exits 0 with --run-commands."

  defp tooltip(:verification_kind, "tagged_tests"),
    do:
      "Reaches LINKED when a test carries @tag spec for the requirement; EXECUTED when that test ran and passed."

  defp tooltip(:verification_kind, kind)
       when kind in ~w(file source_file test_file guide_file readme_file workflow_file test doc workflow contract) do
    "Asserts the named #{String.replace(kind, "_", " ")} exists. Reaches LINKED when its content references the requirement id."
  end

  defp tooltip(:execute, true),
    do: "execute: true — eligible to run during --run-commands"

  defp tooltip(:execute, false),
    do: "execute: false — declared only; will not run automatically"

  defp tooltip(:change, :new), do: "Added in this change set"
  defp tooltip(:change, :modified), do: "Modified in this change set"
  defp tooltip(:change, :removed), do: "Removed in this change set"
  defp tooltip(:change, :new_subject), do: "This subject's spec file did not exist on the base ref"
  defp tooltip(:change, :spec_edited), do: "The subject's .spec.md file was edited in this change set"

  defp tooltip(:severity, "error"),
    do: "Error — blocks the gate. mix spec.check exits non-zero."

  defp tooltip(:severity, "warning"),
    do: "Warning — visible in the report but does not block the gate by default."

  defp tooltip(:severity, "info"),
    do: "Info — advisory; never blocks."

  defp tooltip(:binding_health, :none),
    do:
      "No realized_by bindings declared on this subject. Coverage strength tops out at LINKED until bindings are added."

  defp tooltip(:binding_health, :dangling),
    do:
      "One or more realized_by bindings could not be resolved to actual code. See the dangling-binding findings in the triage panel."

  defp tooltip(:binding_health, :valid),
    do: "All declared realized_by bindings resolve to actual code on this branch."

  defp tooltip(_, _), do: ""

  defp title_attr(text) when is_binary(text) and text != "",
    do: ~s| title="#{html_escape(text)}"|

  defp title_attr(_), do: ""

  defp html_escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp slug(id) when is_binary(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp slug(_), do: "x"

  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(other), do: to_string(other)

  defp field(nil, _key), do: nil

  defp field(item, key) when is_struct(item), do: Map.get(item, key)

  defp field(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end

  # ----------------------------------------------------------------------
  # Embedded CSS / JS
  # ----------------------------------------------------------------------

  defp css do
    """
    :root {
      --bg: #fafafa;
      --fg: #1a1a1a;
      --fg-muted: #6b6b6b;
      --fg-faint: #9a9a9a;
      --card-bg: #ffffff;
      --border: #e5e5e5;
      --border-strong: #cfcfcf;
      --accent: #1e88e5;
      --error: #c62828;
      --error-bg: #ffebee;
      --warning: #ad6500;
      --warning-bg: #fff8e1;
      --info: #1565c0;
      --info-bg: #e3f2fd;
      --success: #2e7d32;
      --success-bg: #e8f5e9;
      --neutral-bg: #f0f0f0;
      --add-bg: #e6ffec;
      --add-fg: #1a7f37;
      --del-bg: #ffeef0;
      --del-fg: #c0152e;
      --hunk-bg: #ddf4ff;
      --hunk-fg: #0a3069;
      --code-font: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
      --body-font: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    }

    * { box-sizing: border-box; }

    html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
    body { font-family: var(--body-font); line-height: 1.5; font-size: 15px; }

    .page-header {
      background: var(--card-bg);
      border-bottom: 1px solid var(--border);
      padding: 24px 32px;
    }
    .page-header-row {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 24px;
      max-width: 1280px;
      margin: 0 auto;
    }
    .page-header h1 {
      margin: 0;
      font-size: 22px;
      font-weight: 600;
      letter-spacing: -0.01em;
    }
    .page-header-meta {
      color: var(--fg-muted);
      font-size: 13px;
      display: flex;
      gap: 16px;
    }
    .ref { font-family: var(--code-font); font-size: 12px; }
    .ref-sep { color: var(--fg-faint); margin: 0 4px; }

    /* GitHub-style diff stats in the page header. */
    .diffstat {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      font-family: var(--code-font);
      font-size: 12px;
    }
    .diffstat-files { color: var(--fg-muted); font-weight: 500; }
    .diffstat-add { color: var(--add-fg); font-weight: 600; }
    .diffstat-del { color: var(--del-fg); font-weight: 600; }
    .diffstat-bar {
      display: inline-flex;
      gap: 2px;
      margin-left: 2px;
    }
    .diffstat-block {
      display: inline-block;
      width: 8px;
      height: 8px;
      border-radius: 1px;
    }
    .diffstat-block-add { background: var(--add-fg); }
    .diffstat-block-del { background: var(--del-fg); }
    .diffstat-block-empty { background: var(--border-strong); }

    /* Top-level Spec / Files toggle. */
    .view-toggle-wrap {
      max-width: 1280px;
      margin: 14px auto 0;
    }
    .view-toggle {
      display: flex;
      width: max-content;
      gap: 4px;
      padding: 4px;
      background: var(--neutral-bg);
      border-radius: 8px;
      border: 1px solid var(--border);
    }
    .view-toggle-btn {
      background: transparent;
      border: none;
      cursor: pointer;
      padding: 8px 16px;
      border-radius: 6px;
      font-family: inherit;
      color: var(--fg-muted);
      display: flex;
      flex-direction: column;
      align-items: flex-start;
      gap: 1px;
      text-align: left;
      transition: background 0.15s ease, color 0.15s ease;
    }
    .view-toggle-btn:hover { color: var(--fg); }
    .view-toggle-btn.active {
      background: var(--card-bg);
      color: var(--fg);
      box-shadow: 0 1px 2px rgba(0, 0, 0, 0.06);
    }
    .view-toggle-label {
      font-size: 13px;
      font-weight: 600;
    }
    .view-toggle-hint {
      font-size: 11px;
      color: var(--fg-faint);
      font-weight: 400;
    }

    /* Spec vs Files view panes. The TOC on the left only makes sense for the
       Spec pane, so it gets hidden when the Files pane is active. */
    .view-pane { display: none; }
    .view-pane.active { display: block; }
    .layout[data-view-mode="files"] > .toc { display: none; }
    .layout[data-view-mode="files"] { grid-template-columns: minmax(0, 1fr); }

    .files-view-explainer { color: var(--fg-muted); margin: 0 0 16px 0; font-size: 13px; }

    /* In Files view we have the horizontal room to keep the picker pinned
       open. The slide-out behavior used by the Spec view's per-subject
       drawers is overridden so the tree panel stays put — no animation,
       no auto-close on scroll, no handle. */
    .files-view .files-section,
    .files-view .files-section.tree-collapsed {
      padding-left: 256px;
      transition: none;
      min-height: 0;
    }
    .files-view .file-tree-panel,
    .files-view .files-section.tree-collapsed .file-tree-panel {
      transform: none !important;
      opacity: 1 !important;
      pointer-events: auto !important;
      transition: none !important;
      display: flex !important;
    }
    .files-view .file-tree-handle,
    .files-view .file-tree-close { display: none !important; }

    .layout {
      max-width: 1280px;
      margin: 0 auto;
      padding: 24px 32px 48px;
      display: grid;
      grid-template-columns: 240px minmax(0, 1fr);
      gap: 32px;
      align-items: start;
    }

    main {
      display: flex;
      flex-direction: column;
      gap: 32px;
      min-width: 0;
    }

    .section-heading {
      font-size: 14px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--fg-muted);
      margin: 0 0 16px 0;
    }

    /* TOC */
    .toc {
      position: sticky;
      top: 16px;
      max-height: calc(100vh - 32px);
      overflow-y: auto;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
      font-size: 13px;
    }
    .toc-list, .toc-sublist { list-style: none; margin: 0; padding: 0; }
    .toc-section { margin: 4px 0; }
    .toc-section > a {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
      color: var(--fg);
      text-decoration: none;
      padding: 6px 8px;
      border-radius: 4px;
      font-weight: 500;
    }
    .toc-section > a:hover { background: var(--neutral-bg); }
    .toc-sublist { margin-top: 4px; padding-left: 8px; border-left: 2px solid var(--border); }
    .toc-sublist li { margin: 2px 0; }
    .toc-sublist a {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 6px;
      color: var(--fg-muted);
      text-decoration: none;
      padding: 4px 8px;
      border-radius: 4px;
      font-weight: 400;
    }
    .toc-sublist a:hover { background: var(--neutral-bg); color: var(--fg); }
    .toc-sublist code { font-size: 11px; }
    .toc-pip {
      display: inline-block;
      min-width: 18px;
      padding: 0 6px;
      border-radius: 9px;
      font-size: 11px;
      font-weight: 600;
      text-align: center;
      line-height: 16px;
    }
    .toc-pip-clean { background: var(--success-bg); color: var(--success); }
    .toc-pip-error { background: var(--error-bg); color: var(--error); }
    .toc-pip-warning { background: var(--warning-bg); color: var(--warning); }
    .toc-pip-info { background: var(--info-bg); color: var(--info); }
    .toc-pip-new { background: #d1fae5; color: #065f46; font-size: 9px; padding: 0 4px; min-width: 0; }
    .toc-pip-edited { background: #ddd6fe; color: #5b21b6; font-size: 9px; padding: 0 4px; min-width: 0; }
    .toc-pips { display: inline-flex; gap: 4px; align-items: center; }

    /* Sync status panel — replaces the old triage panel.
       Always shows what was checked so a first-time reader can see what
       "no findings" actually means. Headline and chain switch from green
       (in-sync) to amber/red (out-of-sync) based on findings. */
    .sync-status {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 20px 24px;
    }
    .sync-status-in {
      background: linear-gradient(180deg, #f0fdf4 0%, var(--card-bg) 60%);
      border-color: #bbf7d0;
    }
    .sync-status-out {
      background: linear-gradient(180deg, #fff7ed 0%, var(--card-bg) 60%);
      border-color: #fed7aa;
    }

    .sync-headline {
      padding-bottom: 16px;
      border-bottom: 1px solid var(--border);
    }
    .sync-headline-row {
      display: flex;
      gap: 16px;
      align-items: flex-start;
    }
    .sync-headline-icon {
      font-size: 28px;
      line-height: 1;
      width: 44px;
      height: 44px;
      border-radius: 50%;
      display: flex;
      align-items: center;
      justify-content: center;
      flex-shrink: 0;
      font-weight: 700;
    }
    .sync-headline-icon-ok { background: #d1fae5; color: #065f46; }
    .sync-headline-icon-fail { background: #fed7aa; color: #9a3412; }

    .sync-headline-text { flex: 1; min-width: 0; }
    .sync-headline-title {
      margin: 0 0 4px 0;
      font-size: 18px;
      font-weight: 600;
      letter-spacing: -0.01em;
    }
    .sync-status-in .sync-headline-title { color: #065f46; }
    .sync-status-out .sync-headline-title { color: #9a3412; }

    .sync-headline-meta {
      margin: 0;
      color: var(--fg-muted);
      font-size: 13px;
    }

    /* Triangulation diagram: 4 nodes (SPEC / CODE / TESTS / COVERAGE) wired
       by 3 edges. Each edge has a hover tooltip explaining the claim it
       represents. Edge color flips green ↔ amber based on whether any
       findings touched that leg. */
    .sync-diagram {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr) auto minmax(0, 1fr) auto minmax(0, 1fr);
      align-items: center;
      gap: 8px;
      margin: 14px 0 0;
    }
    .sync-node {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 10px 8px;
      text-align: center;
      cursor: help;
      transition: border-color 0.12s ease, transform 0.12s ease;
    }
    .sync-node:hover { border-color: var(--accent); transform: translateY(-1px); }
    /* "Empty" node: no data on this side of the chain (e.g. 0 MFAs). Reads
       as muted/dashed so it doesn't look like a victory. */
    .sync-node-empty {
      background: repeating-linear-gradient(
        135deg,
        var(--card-bg) 0,
        var(--card-bg) 6px,
        var(--neutral-bg) 6px,
        var(--neutral-bg) 12px
      );
      border-style: dashed;
      color: var(--fg-muted);
    }
    .sync-node-empty .sync-node-stat { color: var(--fg-muted); font-style: italic; }
    .sync-node-title {
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--fg-muted);
      margin: 0 0 4px;
    }
    .sync-node-stat {
      font-size: 12px;
      color: var(--fg);
      font-family: var(--code-font);
      line-height: 1.3;
    }

    .sync-edge {
      display: flex;
      flex-direction: column;
      align-items: center;
      gap: 2px;
      cursor: help;
      padding: 0 4px;
      min-width: 80px;
    }
    .sync-edge-line {
      height: 2px;
      width: 100%;
      border-radius: 1px;
      background: #10b981;
      position: relative;
    }
    .sync-edge-line::after {
      content: "";
      position: absolute;
      right: -6px;
      top: -3px;
      width: 0;
      height: 0;
      border-left: 6px solid #10b981;
      border-top: 4px solid transparent;
      border-bottom: 4px solid transparent;
    }
    .sync-edge-fail .sync-edge-line { background: #ea580c; }
    .sync-edge-fail .sync-edge-line::after { border-left-color: #ea580c; }
    /* Degraded edge: detector_unavailable on this leg. Solid amber/gray
       — neither a positive proof nor a failure; the system is being
       honest that the detector could not run. */
    .sync-edge-degraded .sync-edge-line { background: #d4a373; }
    .sync-edge-degraded .sync-edge-line::after { border-left-color: #d4a373; }
    .sync-edge-degraded .sync-edge-icon { color: #b45309; }
    .sync-edge-degraded .sync-edge-label { color: #92400e; }
    /* Vacuous edge: nothing to verify on this leg. Dashed gray — neither
       a positive proof nor a failure. */
    .sync-edge-vacuous .sync-edge-line {
      background: transparent;
      border-top: 2px dashed var(--border-strong);
      height: 0;
    }
    .sync-edge-vacuous .sync-edge-line::after { border-left-color: var(--border-strong); }
    .sync-edge-vacuous .sync-edge-icon { color: var(--fg-faint); }
    .sync-edge-vacuous .sync-edge-label { color: var(--fg-faint); }
    .sync-edge-label {
      font-size: 10px;
      color: var(--fg-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      white-space: nowrap;
      font-weight: 600;
    }
    .sync-edge-icon {
      font-weight: 700;
      margin-right: 2px;
    }
    .sync-edge-ok .sync-edge-icon { color: #10b981; }
    .sync-edge-fail .sync-edge-icon { color: #c2410c; }
    .sync-edge:hover .sync-edge-line { height: 3px; }

    @media (max-width: 720px) {
      .sync-diagram {
        grid-template-columns: 1fr;
        gap: 6px;
      }
      .sync-edge { min-width: 0; padding: 4px 0; }
      .sync-edge-line { width: 2px; height: 24px; }
      .sync-edge-line::after {
        right: -3px;
        top: auto;
        bottom: -6px;
        left: -3px;
        border-left: 4px solid transparent;
        border-right: 4px solid transparent;
        border-top: 6px solid;
        border-bottom: none;
      }
      .sync-edge-fail .sync-edge-line::after { border-top-color: #ea580c; border-left-color: transparent; }
      .sync-edge-line::after { border-left-color: transparent; border-top-color: #10b981; }
    }

    .sync-checklist { padding-top: 14px; }
    .sync-checklist-summary {
      cursor: pointer;
      list-style: none;
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.06em;
      color: var(--fg-muted);
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 4px 0 10px;
    }
    .sync-checklist-summary::-webkit-details-marker { display: none; }
    .sync-checklist-summary::before {
      content: "▸";
      color: var(--fg-faint);
      font-size: 10px;
      width: 10px;
    }
    .sync-checklist[open] .sync-checklist-summary::before { content: "▾"; }
    .sync-checklist-summary:hover { color: var(--fg); }
    .sync-check-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .sync-check {
      display: grid;
      grid-template-columns: 22px 110px minmax(0, 1fr) auto;
      gap: 10px;
      align-items: baseline;
      padding: 6px 8px;
      border-radius: 4px;
      font-size: 13px;
      line-height: 1.45;
    }
    .sync-check-ok { background: transparent; }
    .sync-check-fail { background: #fff7ed; border-left: 3px solid #ea580c; padding-left: 6px; }
    .sync-check-degraded { background: #fffbeb; border-left: 3px solid #d4a373; padding-left: 6px; }
    .sync-check-vacuous { background: transparent; opacity: 0.7; }
    .sync-check-icon { font-weight: 700; font-size: 14px; text-align: center; }
    .sync-check-ok .sync-check-icon { color: #10b981; }
    .sync-check-fail .sync-check-icon { color: #c2410c; }
    .sync-check-degraded .sync-check-icon { color: #b45309; }
    .sync-check-vacuous .sync-check-icon { color: var(--fg-faint); }
    .sync-check-vacuous .sync-check-label { color: var(--fg-muted); }
    .sync-check-vacuous-tag {
      font-size: 11px;
      font-style: italic;
      color: var(--fg-muted);
      background: var(--neutral-bg);
      padding: 2px 8px;
      border-radius: 999px;
      white-space: nowrap;
    }
    .sync-check-degraded-tag {
      font-size: 11px;
      font-weight: 600;
      color: #92400e;
      background: #fef3c7;
      padding: 2px 8px;
      border-radius: 999px;
      white-space: nowrap;
    }
    .sync-degraded-banner {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 12px;
      margin-bottom: 10px;
      background: #fffbeb;
      border: 1px solid #fde68a;
      border-left: 4px solid #d4a373;
      border-radius: 4px;
      color: #92400e;
      font-size: 13px;
      line-height: 1.45;
    }
    .sync-degraded-icon {
      font-weight: 700;
      font-size: 16px;
      color: #b45309;
      flex-shrink: 0;
    }
    .sync-degraded-text code {
      font-family: var(--code-font);
      font-size: 11px;
      background: rgba(180, 83, 9, 0.08);
      color: #92400e;
      padding: 1px 5px;
      border-radius: 3px;
    }
    .sync-check-leg {
      font-family: var(--code-font);
      font-size: 11px;
      color: var(--fg-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      font-weight: 600;
    }
    .sync-check-label { color: var(--fg); }
    .sync-check-label code {
      font-family: var(--code-font);
      font-size: 11px;
      background: var(--neutral-bg);
      padding: 1px 5px;
      border-radius: 3px;
    }
    .sync-check-count {
      font-size: 11px;
      font-weight: 700;
      color: #c2410c;
      background: #ffedd5;
      padding: 2px 8px;
      border-radius: 999px;
      white-space: nowrap;
    }
    .sync-check-detail {
      font-size: 11px;
      color: var(--fg-muted);
      font-family: var(--code-font);
      white-space: nowrap;
    }
    .sync-checklist-footnote {
      margin: 14px 0 0 0;
      padding-top: 10px;
      border-top: 1px solid var(--border);
      font-size: 12px;
      color: var(--fg-muted);
      line-height: 1.5;
    }
    .sync-checklist-footnote code {
      font-family: var(--code-font);
      font-size: 11px;
      background: var(--neutral-bg);
      padding: 1px 5px;
      border-radius: 3px;
    }

    /* Per-subject status list under the sync panel. */
    .triage-subjects {
      list-style: none;
      margin: 16px 0 0 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .triage-subject-link {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      padding: 6px 10px;
      border-radius: 4px;
      text-decoration: none;
      color: var(--fg);
      border: 1px solid transparent;
    }
    .triage-subject-link:hover {
      background: var(--neutral-bg);
      border-color: var(--border);
    }
    .badge-clean { background: var(--success-bg); color: var(--success); }

    /* Change-status chips */
    .chip {
      display: inline-flex;
      align-items: center;
      padding: 1px 7px;
      border-radius: 4px;
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.06em;
      text-transform: uppercase;
      border: 1px solid transparent;
      line-height: 1.5;
    }
    .chip-new { background: #d1fae5; color: #065f46; border-color: #a7f3d0; }
    .chip-modified { background: #ddd6fe; color: #5b21b6; border-color: #c4b5fd; }
    .chip-removed { background: #fee2e2; color: #991b1b; border-color: #fecaca; }

    /* Subject Spec-tab change callout */
    .spec-change-callout {
      background: var(--neutral-bg);
      border-left: 3px solid var(--accent);
      padding: 10px 14px;
      border-radius: 4px;
      font-size: 13px;
      margin-bottom: 16px;
      color: var(--fg);
    }
    .spec-change-callout strong { font-weight: 600; }
    .spec-change-new-subject {
      background: #ecfdf5;
      border-left-color: #10b981;
      color: #065f46;
    }

    /* Per-row tinting for new/modified */
    .requirement-new,
    .scenario-new {
      background: #ecfdf5;
      border-left: 3px solid #10b981;
      padding-left: 12px;
      margin-left: -12px;
      border-radius: 0 4px 4px 0;
    }
    .requirement-modified,
    .scenario-modified {
      background: #f5f3ff;
      border-left: 3px solid #8b5cf6;
      padding-left: 12px;
      margin-left: -12px;
      border-radius: 0 4px 4px 0;
    }

    /* Unchanged-items disclosure: collapses unchanged requirements/scenarios
       beneath a "Show N unchanged …" toggle so the Spec tab leads with what
       actually changed in this PR. */
    .unchanged-disclosure {
      margin-top: 16px;
      border-top: 1px dashed var(--border);
      padding-top: 12px;
    }
    .unchanged-summary {
      cursor: pointer;
      list-style: none;
      font-size: 12px;
      font-weight: 500;
      color: var(--fg-muted);
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      background: var(--neutral-bg);
      border-radius: 999px;
      user-select: none;
    }
    .unchanged-summary::-webkit-details-marker { display: none; }
    .unchanged-summary::before {
      content: "▸";
      color: var(--fg-faint);
      font-size: 10px;
    }
    .unchanged-disclosure[open] .unchanged-summary::before { content: "▾"; }
    .unchanged-summary:hover { color: var(--fg); background: var(--border); }
    .unchanged-disclosure[open] > .requirement-list,
    .unchanged-disclosure[open] > .scenario-list { margin-top: 12px; }

    /* Removed-items section */
    .tab-heading-removed { color: var(--error); }
    .removed-list { list-style: none; margin: 0 0 16px 0; padding: 0; }
    .removed-item {
      padding: 10px 12px;
      background: #fef2f2;
      border-left: 3px solid #ef4444;
      border-radius: 0 4px 4px 0;
      margin-bottom: 8px;
    }
    .removed-header {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      margin-bottom: 4px;
    }
    .removed-statement { margin: 0; color: #7f1d1d; text-decoration: line-through; opacity: 0.85; }

    /* ADR change-status accents */
    .adr-new { border-left: 3px solid #10b981; }
    .adr-modified { border-left: 3px solid #8b5cf6; }
    .adr-removed { border-left: 3px solid #ef4444; }

    .pill {
      display: inline-block;
      padding: 2px 10px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 500;
      line-height: 1.6;
      background: var(--neutral-bg);
      color: var(--fg-muted);
      white-space: nowrap;
    }
    .pill-error { background: var(--error-bg); color: var(--error); }
    .pill-warning { background: var(--warning-bg); color: var(--warning); }
    .pill-info { background: var(--info-bg); color: var(--info); }
    .pill-success { background: var(--success-bg); color: var(--success); }
    .pill-neutral { background: var(--neutral-bg); color: var(--fg-muted); }
    .pill-muted { background: transparent; color: var(--fg-faint); border: 1px solid var(--border); }
    .pill-cover { background: #f5f0ff; color: #5b3aaa; font-family: var(--code-font); font-size: 11px; }
    .pill-priority-must { background: #fee2e2; color: #b91c1c; font-weight: 600; }
    .pill-priority-should { background: #fef3c7; color: #92400e; }
    .pill-priority-may { background: #e0f2fe; color: #0369a1; }

    /* ADR status pills — "accepted" should read affirmatively, not as
       neutral chrome. Other statuses get colors that match their meaning. */
    .pill-status-accepted { background: #d1fae5; color: #065f46; font-weight: 600; }
    .pill-status-proposed { background: #e0f2fe; color: #075985; }
    .pill-status-deprecated { background: #fef3c7; color: #92400e; }
    .pill-status-superseded { background: #f3f4f6; color: #6b7280; text-decoration: line-through; }
    .pill-status-rejected { background: #fee2e2; color: #991b1b; }
    .pill-status-draft { background: #f3e8ff; color: #6b21a8; }

    .badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      line-height: 1.6;
    }
    .badge-error { background: var(--error-bg); color: var(--error); }
    .badge-warning { background: var(--warning-bg); color: var(--warning); }
    .badge-info { background: var(--info-bg); color: var(--info); }

    .badge-binding-health { text-transform: none; letter-spacing: 0; }
    .badge-binding-empty { background: #f3f4f6; color: var(--fg-muted); }
    .badge-binding-dangling { background: var(--error-bg); color: var(--error); }
    .badge-binding-valid { background: var(--success-bg); color: var(--success); }

    .findings-list { margin-top: 16px; }
    .findings-list summary {
      cursor: pointer;
      font-size: 13px;
      color: var(--fg-muted);
      font-weight: 500;
      padding: 8px 0;
      border-top: 1px solid var(--border);
    }
    .findings-list ul { list-style: none; margin: 0; padding: 0; }
    .finding-item {
      display: grid;
      grid-template-columns: 80px 220px 200px 1fr;
      gap: 12px;
      padding: 8px 0;
      border-top: 1px solid var(--border);
      font-size: 13px;
      align-items: baseline;
    }
    .finding-severity { font-weight: 600; text-transform: uppercase; font-size: 11px; letter-spacing: 0.04em; }
    .finding-error .finding-severity { color: var(--error); }
    .finding-warning .finding-severity { color: var(--warning); }
    .finding-info .finding-severity { color: var(--info); }
    .finding-code { font-family: var(--code-font); font-size: 12px; color: var(--fg-muted); }
    .finding-subject { font-family: var(--code-font); font-size: 12px; color: var(--accent); text-decoration: none; }
    .finding-subject:hover { text-decoration: underline; }
    .finding-message { color: var(--fg); }

    /* Subject card */
    .subject {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      margin-bottom: 16px;
      overflow: hidden;
      scroll-margin-top: 16px;
    }
    .subject-header {
      padding: 24px 24px 16px;
      border-bottom: 1px solid var(--border);
    }
    .subject-statement {
      margin: 0 0 12px 0;
      font-size: 17px;
      line-height: 1.5;
      font-weight: 500;
      color: var(--fg);
      letter-spacing: -0.005em;
    }
    .subject-meta-row {
      display: flex;
      align-items: center;
      gap: 12px;
      flex-wrap: wrap;
    }
    .subject-id {
      font-family: var(--code-font);
      font-size: 12px;
      color: var(--fg-muted);
      background: var(--neutral-bg);
      padding: 2px 8px;
      border-radius: 4px;
    }
    .subject-file {
      font-family: var(--code-font);
      font-size: 12px;
      color: var(--fg-faint);
    }

    /* Tabs */
    .tabs {
      display: flex;
      gap: 0;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
      padding: 0 12px;
    }
    .tab {
      background: none;
      border: none;
      border-bottom: 2px solid transparent;
      padding: 12px 16px;
      font-size: 13px;
      font-weight: 500;
      color: var(--fg-muted);
      cursor: pointer;
      font-family: inherit;
      margin-bottom: -1px;
    }
    .tab:hover { color: var(--fg); }
    .tab.active {
      color: var(--fg);
      border-bottom-color: var(--accent);
      background: var(--card-bg);
    }
    .tab-panels { padding: 24px; }
    .tab-panel { display: none; }
    .tab-panel.active { display: block; }

    .tab-heading {
      margin: 0 0 12px 0;
      font-size: 13px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--fg-muted);
    }
    .tab-heading:not(:first-child) { margin-top: 32px; }

    .empty-tab { color: var(--fg-faint); font-style: italic; margin: 0; }

    /* Requirements */
    .requirement-list { list-style: none; margin: 0; padding: 0; }
    .requirement {
      padding: 16px 0;
      border-top: 1px solid var(--border);
    }
    .requirement:first-child { border-top: none; padding-top: 0; }
    .requirement-header {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      align-items: center;
      margin-bottom: 6px;
    }
    .requirement-id {
      font-family: var(--code-font);
      font-size: 12px;
      color: var(--fg);
      background: var(--neutral-bg);
      padding: 2px 8px;
      border-radius: 4px;
    }
    .requirement-statement { margin: 0; color: var(--fg); }

    /* Scenarios */
    .scenario-list { list-style: none; margin: 0; padding: 0; }
    .scenario {
      padding: 16px 0;
      border-top: 1px solid var(--border);
    }
    .scenario:first-child { border-top: none; padding-top: 0; }
    .scenario-header {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      align-items: center;
      margin-bottom: 8px;
    }
    .scenario-id {
      font-family: var(--code-font);
      font-size: 12px;
      color: var(--fg);
      background: var(--neutral-bg);
      padding: 2px 8px;
      border-radius: 4px;
    }
    .gherkin { font-size: 14px; }
    .gherkin-row {
      display: grid;
      grid-template-columns: 64px minmax(0, 1fr);
      gap: 4px 12px;
      align-items: start;
      margin-bottom: 6px;
    }
    .gherkin-row:last-child { margin-bottom: 0; }
    .gherkin-label {
      color: var(--fg-muted);
      font-weight: 600;
      text-transform: uppercase;
      font-size: 11px;
      letter-spacing: 0.05em;
      padding-top: 3px;
    }
    .gherkin-items {
      list-style: none;
      margin: 0;
      padding: 0;
      color: var(--fg);
    }
    .gherkin-items li { margin: 0; padding: 1px 0; line-height: 1.45; }
    .gherkin-items li::before {
      content: "•";
      color: var(--fg-faint);
      margin-right: 8px;
      display: inline-block;
    }

    /* Bindings */
    .bindings { margin: 0; }
    .bindings dt {
      font-family: var(--code-font);
      font-size: 12px;
      color: var(--fg-muted);
      text-transform: uppercase;
      letter-spacing: 0.04em;
      font-weight: 600;
      margin-top: 12px;
    }
    .bindings dt:first-child { margin-top: 0; }
    .bindings dd { margin: 0; padding: 0; }
    .mfa-list { list-style: none; margin: 4px 0 12px 0; padding: 0; }
    .mfa-list li { font-family: var(--code-font); font-size: 12px; padding: 2px 0; }

    /* Coverage tab — help disclosure */
    .coverage-help {
      background: var(--bg);
      border: 1px solid var(--border);
      border-left: 3px solid var(--accent);
      border-radius: 4px;
      margin-bottom: 16px;
    }
    .coverage-help-summary {
      cursor: pointer;
      list-style: none;
      padding: 8px 14px;
      font-size: 13px;
      font-weight: 500;
      color: var(--accent);
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .coverage-help-summary::-webkit-details-marker { display: none; }
    .coverage-help-summary::after {
      content: "▸";
      color: var(--fg-faint);
      font-size: 10px;
      margin-left: auto;
    }
    .coverage-help[open] .coverage-help-summary::after { content: "▾"; }
    .coverage-help-body {
      padding: 4px 18px 14px;
      font-size: 13px;
      line-height: 1.55;
      color: var(--fg);
    }
    .coverage-help-body p { margin: 8px 0; }
    .coverage-help-body code { font-family: var(--code-font); font-size: 12px; background: var(--neutral-bg); padding: 1px 5px; border-radius: 3px; }
    .coverage-help-tiers {
      margin: 8px 0;
      display: grid;
      grid-template-columns: 110px 1fr;
      gap: 8px 14px;
      align-items: start;
    }
    .coverage-help-tiers dt { padding-top: 2px; }
    .coverage-help-tiers dd { margin: 0; }

    /* Raw verification (collapsed by default) */
    .raw-verification {
      margin-top: 24px;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--bg);
    }
    .raw-verification-summary {
      cursor: pointer;
      list-style: none;
      padding: 8px 14px;
      font-size: 13px;
      font-weight: 600;
      color: var(--fg-muted);
      display: flex;
      align-items: center;
      gap: 6px;
    }
    .raw-verification-summary::-webkit-details-marker { display: none; }
    .raw-verification-summary::before {
      content: "▸";
      color: var(--fg-faint);
      font-size: 10px;
    }
    .raw-verification[open] .raw-verification-summary::before { content: "▾"; }
    .raw-verification-explainer { padding: 0 14px; margin: 4px 0 12px; color: var(--fg-muted); font-size: 12px; font-style: italic; }
    .raw-verification .verification-list { padding: 0 14px 14px; margin: 0; }
    .raw-verification-all { margin-top: 32px; }
    .raw-verification-subject { padding: 0 14px 4px; }
    .raw-verification-subject-heading {
      margin: 12px 0 6px;
      font-size: 12px;
      font-weight: 600;
      color: var(--fg-muted);
      text-transform: none;
      letter-spacing: 0;
    }
    .raw-verification-subject-heading a { color: inherit; text-decoration: none; }
    .raw-verification-subject-heading a:hover { text-decoration: underline; }
    .raw-verification-subject-heading code { font-family: var(--code-font); font-size: 12px; }
    .raw-verification-subject-count { color: var(--fg-faint); font-weight: 400; margin-left: 4px; }
    .raw-verification-subject .verification-list { padding: 0; margin: 0 0 8px; }

    /* Per-tab pointer back to the page-level coverage help disclosure. */
    .coverage-help-link {
      margin: 0 0 12px;
      font-size: 12px;
      color: var(--fg-muted);
    }
    .coverage-help-link a { color: var(--accent); text-decoration: none; }
    .coverage-help-link a:hover { text-decoration: underline; }

    /* Misc panel — flat-files variant (used when N <= threshold). */
    .files-section-flat .files-list { margin: 0; }

    /* Help cursor on every titled chip so users discover hover content. */
    [title] { cursor: help; }
    a[title], button[title] { cursor: pointer; }

    /* Coverage tab — per-requirement strength */
    .strength-legend {
      display: flex;
      align-items: center;
      gap: 6px;
      flex-wrap: wrap;
      padding: 8px 12px;
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      margin-bottom: 12px;
      font-size: 11px;
    }
    .strength-legend-arrow { color: var(--fg-faint); font-weight: 600; }
    .strength-legend-note { color: var(--fg-muted); margin-left: auto; font-style: italic; }
    .strength-badge {
      display: inline-block;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 10px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      border: 1px solid transparent;
      line-height: 1.5;
    }
    .strength-executed { background: #d1fae5; color: #065f46; border-color: #a7f3d0; }
    .strength-linked { background: #fef3c7; color: #854d0e; border-color: #fde68a; }
    .strength-claimed { background: #e5e7eb; color: #4b5563; border-color: #d1d5db; }
    .strength-uncovered { background: #fee2e2; color: #991b1b; border-color: #fecaca; }
    .strength-warn { color: var(--error); font-weight: 700; margin-left: 4px; }

    .cov-req-list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
    .cov-req {
      padding: 10px 12px;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--card-bg);
      border-left-width: 3px;
    }
    .cov-req-executed { border-left-color: #10b981; }
    .cov-req-linked { border-left-color: #d97706; }
    .cov-req-claimed { border-left-color: #9ca3af; }
    .cov-req-uncovered { border-left-color: #ef4444; background: #fef2f2; }
    .cov-req-header {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-bottom: 4px;
    }
    .cov-req-statement { margin: 0 0 8px 0; color: var(--fg); font-size: 13px; line-height: 1.5; }

    .claim-list { list-style: none; margin: 4px 0 0 0; padding: 0; display: flex; flex-direction: column; gap: 4px; }
    .claim {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      padding: 4px 8px;
      background: var(--bg);
      border-radius: 3px;
      font-size: 12px;
    }
    .claim-target { font-family: var(--code-font); font-size: 11px; color: var(--fg-muted); flex: 1; min-width: 0; overflow-wrap: anywhere; }

    /* Verification */
    .verification-list { list-style: none; margin: 0; padding: 0; }
    .verification {
      padding: 12px 0;
      border-top: 1px solid var(--border);
    }
    .verification:first-child { border-top: none; padding-top: 0; }
    .verification-header {
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      margin-bottom: 6px;
    }
    .verification-target { font-family: var(--code-font); font-size: 12px; }
    .verification-covers { display: flex; gap: 4px; flex-wrap: wrap; padding-left: 4px; }

    /* Decisions */
    .decision-ref-list { list-style: none; margin: 0; padding: 0; }
    .decision-ref-list li { padding: 4px 0; font-family: var(--code-font); font-size: 13px; }

    .adr-list { display: flex; flex-direction: column; gap: 8px; }
    .adr {
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--bg);
    }
    .adr[open] { background: var(--card-bg); }
    .adr-summary {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      padding: 10px 14px;
      cursor: pointer;
      list-style: none;
      font-size: 13px;
    }
    .adr-summary::-webkit-details-marker { display: none; }
    .adr-summary::before {
      content: "▸";
      color: var(--fg-faint);
      font-size: 10px;
      width: 10px;
      transition: transform 0.1s ease;
    }
    .adr[open] .adr-summary::before { transform: rotate(90deg); }
    .adr-id { font-family: var(--code-font); font-size: 12px; color: var(--fg); background: var(--neutral-bg); padding: 2px 8px; border-radius: 4px; }
    .adr-title { color: var(--fg); flex: 1; min-width: 0; }
    .adr-title-missing { color: var(--fg-faint); font-style: italic; flex: 1; }
    .adr-date { color: var(--fg-muted); font-size: 12px; font-family: var(--code-font); }
    .adr-body-wrap { padding: 0 14px 14px; }
    .adr-source { padding-top: 6px; font-size: 11px; color: var(--fg-faint); text-align: right; }

    /* GitHub-style markdown rendering for ADR bodies. */
    .markdown-body {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 16px 20px;
      font-family: var(--body-font);
      font-size: 14px;
      line-height: 1.6;
      color: var(--fg);
      max-height: 560px;
      overflow-y: auto;
      word-wrap: break-word;
    }
    .markdown-body > *:first-child { margin-top: 0; }
    .markdown-body > *:last-child { margin-bottom: 0; }
    .markdown-body h1, .markdown-body h2, .markdown-body h3, .markdown-body h4, .markdown-body h5, .markdown-body h6 {
      margin: 24px 0 12px;
      font-weight: 600;
      line-height: 1.25;
      color: var(--fg);
    }
    .markdown-body h1 { font-size: 22px; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
    .markdown-body h2 { font-size: 18px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }
    .markdown-body h3 { font-size: 16px; }
    .markdown-body h4 { font-size: 14px; }
    .markdown-body h5 { font-size: 13px; color: var(--fg-muted); }
    .markdown-body h6 { font-size: 12px; color: var(--fg-muted); text-transform: uppercase; letter-spacing: 0.04em; }
    .markdown-body p { margin: 0 0 12px; }
    .markdown-body a { color: var(--accent); text-decoration: none; }
    .markdown-body a:hover { text-decoration: underline; }
    .markdown-body strong { font-weight: 600; }
    .markdown-body em { font-style: italic; }
    .markdown-body code {
      font-family: var(--code-font);
      font-size: 0.9em;
      background: var(--neutral-bg);
      border-radius: 3px;
      padding: 1px 5px;
      color: var(--fg);
    }
    .markdown-body pre {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 12px 14px;
      overflow-x: auto;
      font-size: 12px;
      line-height: 1.45;
      margin: 0 0 12px;
    }
    .markdown-body pre > code {
      background: transparent;
      padding: 0;
      border-radius: 0;
      font-size: inherit;
    }
    .markdown-body ul, .markdown-body ol {
      margin: 0 0 12px;
      padding-left: 24px;
    }
    .markdown-body li { margin: 4px 0; }
    .markdown-body li > p { margin: 4px 0; }
    .markdown-body blockquote {
      margin: 0 0 12px;
      padding: 4px 12px;
      color: var(--fg-muted);
      border-left: 3px solid var(--border-strong);
      background: var(--bg);
    }
    .markdown-body blockquote > :first-child { margin-top: 0; }
    .markdown-body blockquote > :last-child { margin-bottom: 0; }
    .markdown-body hr {
      border: none;
      border-top: 1px solid var(--border);
      margin: 16px 0;
    }
    .markdown-body table {
      border-collapse: collapse;
      margin: 0 0 12px;
      font-size: 13px;
      display: block;
      overflow-x: auto;
    }
    .markdown-body table th, .markdown-body table td {
      border: 1px solid var(--border);
      padding: 6px 12px;
      text-align: left;
    }
    .markdown-body table th { background: var(--neutral-bg); font-weight: 600; }
    .markdown-body table tr:nth-child(2n) td { background: var(--bg); }
    .markdown-body img { max-width: 100%; height: auto; }

    .decisions-changed {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
    }
    .decision-changed-list {
      display: flex;
      flex-direction: column;
      gap: 12px;
    }
    .affects { color: var(--fg-muted); font-size: 12px; }

    .decision-affects {
      padding: 8px 12px;
      margin: 0 0 12px;
      background: var(--neutral-bg);
      border-radius: 4px;
      font-size: 12px;
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      align-items: baseline;
    }
    .decision-affects-label {
      font-weight: 600;
      color: var(--fg-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      font-size: 11px;
    }
    .decision-affects-link {
      font-family: var(--code-font);
      color: var(--accent);
      text-decoration: none;
      padding: 1px 6px;
      border-radius: 3px;
      background: var(--card-bg);
      border: 1px solid var(--border);
    }
    .decision-affects-link:hover {
      background: var(--info-bg);
      border-color: var(--info);
    }
    .decision-affects-link code { font-size: 11px; }

    /* Misc panel */
    .misc {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
    }
    .misc-explainer { color: var(--fg-muted); margin: 0 0 16px 0; font-size: 13px; }
    .misc-breakdown {
      background: var(--bg);
      border: 1px solid var(--border);
      border-left: 3px solid var(--accent);
      border-radius: 4px;
      padding: 12px 14px;
      margin: 0 0 16px;
    }
    .misc-breakdown-label {
      display: block;
      font-size: 12px;
      font-weight: 600;
      color: var(--fg-muted);
      text-transform: uppercase;
      letter-spacing: 0.05em;
      margin-bottom: 6px;
    }
    .misc-breakdown-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 4px;
      font-size: 13px;
      color: var(--fg);
    }
    .misc-breakdown-list strong { font-family: var(--code-font); font-weight: 700; }
    .misc-breakdown-detail { color: var(--fg-muted); font-size: 12px; }
    .misc-breakdown-detail a { color: var(--accent); text-decoration: none; }
    .misc-breakdown-detail a:hover { text-decoration: underline; }
    .misc-change, .code-change {
      margin-bottom: 12px;
      border: 1px solid var(--border);
      border-radius: 4px;
      background: var(--card-bg);
      scroll-margin-top: 16px;
    }
    .misc-change:last-child, .code-change:last-child { margin-bottom: 0; }
    .filename {
      background: var(--neutral-bg);
      padding: 8px 12px;
      font-size: 12px;
      cursor: pointer;
      list-style: none;
      display: flex;
      align-items: center;
      gap: 8px;
      border-radius: 4px;
    }
    .misc-change[open] > .filename, .code-change[open] > .filename {
      border-radius: 4px 4px 0 0;
      border-bottom: 1px solid var(--border);
    }
    .filename::-webkit-details-marker { display: none; }
    .filename::before {
      content: "▾";
      color: var(--fg-faint);
      font-size: 10px;
      width: 10px;
    }
    .misc-change:not([open]) > .filename::before,
    .code-change:not([open]) > .filename::before { content: "▸"; }
    .filename code { font-family: var(--code-font); }
    .misc-change > .diff, .code-change > .diff {
      border: none;
      border-radius: 0 0 4px 4px;
    }

    /* Files section: slide-out file-tree drawer next to file diffs.
       The drawer/handle live in an absolutely-positioned rail so they
       never claim vertical layout space — file diffs always start at
       the top of the section. Sticky positioning inside the rail makes
       both the panel and the handle follow the user's scroll. */
    .files-section {
      position: relative;
      padding-left: 256px;
      transition: padding-left 0.25s ease;
      /* Ensure the absolutely-positioned drawer rail (height:100% of this
         section) always has room to render even when every file diff is
         collapsed and the right column is tiny. Without this the parent
         subject card's overflow:hidden clips the drawer. */
      min-height: 320px;
    }
    .files-section.tree-collapsed { padding-left: 32px; }

    .file-tree-rail {
      position: absolute;
      top: 0;
      left: 0;
      width: 240px;
      height: 100%;
      pointer-events: none;
    }

    .file-tree-panel,
    .file-tree-handle {
      pointer-events: auto;
      position: sticky;
      top: 16px;
    }

    .file-tree-panel {
      width: 240px;
      max-height: calc(100vh - 32px);
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      display: flex;
      flex-direction: column;
      overflow: hidden;
      transform: translateX(0);
      opacity: 1;
      transition: transform 0.25s ease, opacity 0.2s ease;
      z-index: 1;
    }
    .files-section.tree-collapsed .file-tree-panel {
      transform: translateX(calc(-100% - 16px));
      opacity: 0;
      pointer-events: none;
    }

    .file-tree-header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 8px 12px;
      border-bottom: 1px solid var(--border);
      background: var(--card-bg);
    }
    .file-tree-title {
      font-size: 11px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--fg-muted);
    }
    .file-tree-close {
      background: none;
      border: none;
      cursor: pointer;
      font-size: 18px;
      line-height: 1;
      color: var(--fg-faint);
      padding: 0 4px;
      font-family: inherit;
    }
    .file-tree-close:hover { color: var(--fg); }
    .file-tree-scroll {
      flex: 1;
      overflow-y: auto;
      padding: 8px 0;
    }

    .file-tree-handle {
      width: 24px;
      height: 64px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0 4px 4px 0;
      border-left: none;
      cursor: pointer;
      display: none;
      align-items: center;
      justify-content: center;
      color: var(--fg-muted);
      font-size: 13px;
      font-family: inherit;
      padding: 0;
      z-index: 2;
    }
    .file-tree-handle:hover { background: var(--neutral-bg); color: var(--fg); }
    .files-section.tree-collapsed .file-tree-handle { display: flex; }
    .files-section.tree-collapsed .file-tree-panel { display: none; }
    .file-tree-handle-icon { display: inline-block; }

    .files-list { min-width: 0; }

    .tree { list-style: none; margin: 0; padding: 0 12px; font-family: var(--code-font); font-size: 12px; }
    .tree .tree { padding: 0 0 0 14px; margin-top: 2px; border-left: 1px dotted var(--border-strong); margin-left: 6px; }
    .tree-folder { padding: 1px 0; color: var(--fg); }
    .tree-folder > details > summary {
      cursor: pointer;
      list-style: none;
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 2px 4px;
      border-radius: 3px;
    }
    .tree-folder > details > summary:hover { background: var(--neutral-bg); }
    .tree-folder > details > summary::-webkit-details-marker { display: none; }
    .tree-folder > details > summary::before {
      content: "▾";
      color: var(--fg-faint);
      font-size: 9px;
      width: 10px;
      display: inline-block;
    }
    .tree-folder > details:not([open]) > summary::before { content: "▸"; }
    .tree-leaf { padding: 1px 0; }
    .tree-leaf a {
      display: flex;
      align-items: center;
      gap: 4px;
      color: var(--accent);
      text-decoration: none;
      padding: 2px 4px;
      padding-left: 14px;
      border-radius: 3px;
    }
    .tree-leaf a:hover { background: var(--neutral-bg); text-decoration: underline; }

    @media (max-width: 760px) {
      .files-section, .files-section.tree-collapsed { padding-left: 0; }
      .file-tree-rail { position: static; width: auto; height: auto; pointer-events: auto; }
      .file-tree-panel {
        position: static;
        width: 100%;
        max-height: 240px;
        transform: none !important;
        opacity: 1 !important;
        pointer-events: auto !important;
        margin-bottom: 12px;
        display: flex !important;
      }
      .file-tree-handle { display: none !important; }
    }

    /* Diff */
    .diff {
      background: var(--card-bg);
      border-radius: 0 0 4px 4px;
      overflow-x: auto;
      font-family: var(--code-font);
      font-size: 12px;
      line-height: 1.5;
    }
    .diff-row {
      display: grid;
      grid-template-columns: 44px 44px 18px minmax(0, 1fr);
      align-items: stretch;
    }
    .diff-lineno {
      text-align: right;
      padding: 0 6px 0 4px;
      color: var(--fg-faint);
      font-size: 11px;
      user-select: none;
      background: var(--bg);
      white-space: pre;
    }
    .diff-marker {
      user-select: none;
      text-align: center;
      padding: 0 2px;
      color: var(--fg-faint);
      font-weight: 500;
    }
    .diff-content {
      padding: 0 8px;
      white-space: pre;
      color: var(--fg);
      overflow-wrap: normal;
    }
    .diff-row-ctx { background: var(--card-bg); }
    .diff-row-add { background: var(--add-bg); }
    .diff-row-add .diff-lineno-new { background: #ccffd8; color: #1a7f37; }
    .diff-row-add .diff-marker { color: #1a7f37; }
    .diff-row-add .diff-content { color: #14532d; }
    .diff-row-del { background: var(--del-bg); }
    .diff-row-del .diff-lineno-old { background: #ffd1ce; color: #82071e; }
    .diff-row-del .diff-marker { color: #82071e; }
    .diff-row-del .diff-content { color: #6e0a17; }
    .diff-row-hunk { background: var(--hunk-bg); color: var(--hunk-fg); }
    .diff-row-hunk .diff-lineno { background: var(--hunk-bg); color: var(--hunk-fg); }
    .diff-row-hunk .diff-content { padding: 4px 8px; font-weight: 500; color: var(--hunk-fg); }

    /* Prism integration: keep our diff-row backgrounds + line styling
       intact while letting Prism color the tokens inside .diff-content.
       Prism ships a rule:
         :not(pre)>code[class*=language-]{padding:.1em;border-radius:.3em;
                                         white-space:normal;background:#f5f2f0}
       which would collapse our diff whitespace and add an inline pill
       look. The override below has higher specificity (class + attribute
       on the same element) plus !important on the load-bearing
       properties so token highlighting still works but the layout
       belongs to us. */
    code.diff-content,
    :not(pre) > code.diff-content[class*="language-"] {
      display: inline;
      background: transparent !important;
      padding: 0 8px !important;
      margin: 0;
      border-radius: 0 !important;
      font-family: var(--code-font);
      font-size: inherit;
      color: inherit;
      white-space: pre !important;
      word-break: normal !important;
      word-wrap: normal !important;
      text-shadow: none;
      tab-size: 4;
      -moz-tab-size: 4;
    }
    pre[class*="language-"], code[class*="language-"] {
      text-shadow: none;
      background: transparent;
      box-shadow: none;
    }
    /* Tone Prism's token colors a touch so they read well on the soft
       add/del backgrounds. */
    .diff-row-add code .token.deleted,
    .diff-row-del code .token.inserted { background: transparent; }

    /* Footer */
    .page-footer {
      max-width: 1280px;
      margin: 0 auto;
      padding: 16px 32px 32px;
      color: var(--fg-faint);
      font-size: 12px;
      text-align: right;
    }

    /* Anchor scroll offsets so sticky headers don't cover the target */
    #triage, #subjects, #decisions-changed, #misc, .subject { scroll-margin-top: 16px; }

    @media (max-width: 960px) {
      .layout { grid-template-columns: 1fr; }
      .toc { position: static; max-height: none; }
    }

    @media (max-width: 720px) {
      .page-header, .layout, .page-footer { padding-left: 16px; padding-right: 16px; }
      .finding-item { grid-template-columns: 1fr; gap: 4px; }
    }
    """
  end

  defp js do
    """
    // Top-level Spec / Files view toggle.
    document.addEventListener('click', function (e) {
      var btn = e.target.closest('.view-toggle-btn');
      if (!btn) return;
      var mode = btn.getAttribute('data-view');
      var layout = document.querySelector('.layout');
      if (!layout) return;
      layout.setAttribute('data-view-mode', mode);
      document.querySelectorAll('.view-toggle-btn').forEach(function (b) {
        var active = b.getAttribute('data-view') === mode;
        b.classList.toggle('active', active);
        b.setAttribute('aria-selected', active ? 'true' : 'false');
      });
      document.querySelectorAll('.view-pane').forEach(function (p) {
        p.classList.toggle('active', p.getAttribute('data-view-pane') === mode);
      });
    });

    // Tab switching inside subject cards.
    document.addEventListener('click', function (e) {
      var btn = e.target.closest('.tab');
      if (!btn) return;
      var subjectCard = btn.closest('.subject');
      if (!subjectCard) return;
      var targetId = btn.getAttribute('data-tab');
      subjectCard.querySelectorAll('.tab').forEach(function (t) { t.classList.remove('active'); });
      subjectCard.querySelectorAll('.tab-panel').forEach(function (p) { p.classList.remove('active'); });
      btn.classList.add('active');
      var panel = subjectCard.querySelector('#' + CSS.escape(targetId));
      if (panel) panel.classList.add('active');
    });

    // File-tree drawer: open / close / close-on-leaf-click.
    // Sections inside the Files view are pinned open and exempt.
    function isPinned(section) {
      return !!(section && section.closest('.files-view'));
    }

    function closeAllTrees() {
      document.querySelectorAll('.files-section:not(.tree-collapsed)').forEach(function (s) {
        if (isPinned(s)) return;
        s.classList.add('tree-collapsed');
      });
    }

    document.addEventListener('click', function (e) {
      var openHandle = e.target.closest('[data-tree-action=\\"open\\"]');
      if (openHandle) {
        var section = openHandle.closest('.files-section');
        if (section && !isPinned(section)) section.classList.remove('tree-collapsed');
        return;
      }
      var closeBtn = e.target.closest('[data-tree-action=\\"close\\"]');
      if (closeBtn) {
        var section = closeBtn.closest('.files-section');
        if (section && !isPinned(section)) section.classList.add('tree-collapsed');
        return;
      }
      var leaf = e.target.closest('[data-tree-leaf]');
      if (leaf) {
        var section = leaf.closest('.files-section');
        if (section && !isPinned(section)) section.classList.add('tree-collapsed');
        // Let the anchor navigation proceed.
      }
    });

    // Close drawers on user-initiated scroll. Wait briefly after load so the
    // browser's own scroll-to-hash on initial load doesn't immediately close
    // every drawer.
    setTimeout(function () {
      var lastY = window.scrollY;
      window.addEventListener('scroll', function () {
        var dy = Math.abs(window.scrollY - lastY);
        lastY = window.scrollY;
        if (dy > 4) closeAllTrees();
      }, { passive: true });
    }, 600);

    // Trigger Prism syntax highlighting once the DOM is ready. Each
    // .diff-content with a `language-X` class gets tokenized and replaced
    // with span-wrapped tokens. We avoid Prism's auto-loader by pre-loading
    // the languages we ship.
    if (typeof Prism !== 'undefined' && Prism.highlightAll) {
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', function () { Prism.highlightAll(); });
      } else {
        Prism.highlightAll();
      }
    }
    """
  end
end
