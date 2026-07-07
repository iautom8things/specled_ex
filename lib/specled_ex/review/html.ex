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

  EEx.function_from_string(
    :defp,
    :page,
    ~S"""
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Spec Review · <%= h(view.meta.head_ref) %></title>
      <script><%= theme_bootstrap_js() %></script>
      <style><%= prism_css() %></style>
      <style><%= css %></style>
    </head>
    <body>
      <header class="topbar">
        <div class="topbar-left">
          <h1>Spec Review</h1>
          <span class="ref"><%= h(view.meta.base_ref) %><span class="ref-sep">…</span><%= h(view.meta.head_ref) %></span>
          <%= render_diff_stats(view.meta.stats) %>
        </div>
        <div class="topbar-right">
          <%= render_verdict_chip(view.findings_delta) %>
          <%= render_theme_toggle() %>
        </div>
      </header>
      <div class="layout">
        <aside class="queue" aria-label="Review queue">
          <%= render_queue(view) %>
        </aside>
        <main class="detail">
          <section class="detail-pane active" data-unit="overview" id="unit-overview" tabindex="-1">
            <%= render_overview(view) %>
          </section>
          <section class="detail-pane" data-unit="decisions" id="unit-decisions" tabindex="-1">
            <%= render_decisions_changed(view.decisions_changed, view.adrs_by_id, view.all_findings) %>
          </section>
          <%= render_subject_panes(view.affected_subjects, view.adrs_by_id) %>
          <section class="detail-pane" data-unit="misc" id="unit-misc" tabindex="-1">
            <%= render_unmapped(view.unmapped_changes, view.file_breakdown) %>
          </section>
          <section class="detail-pane" data-unit="files" id="unit-files" tabindex="-1">
            <%= render_files_view(view.all_changes, view.meta.stats) %>
          </section>
          <section class="detail-pane" data-unit="health" id="unit-health" tabindex="-1">
            <%= render_spec_health(view) %>
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
    """,
    [:view, :css, :js]
  )

  @doc false
  def prism_js, do: @prism_js
  @doc false
  def prism_css, do: @prism_css

  # covers: specled.spec_review.review_queue_navigation
  # The left rail lists every reviewable unit as a queue: Overview, Decisions
  # changed, the affected subjects grouped by change kind (spec edited / code
  # only / impacted only) and ordered by change size, the outside-the-spec
  # panel, the all-files view, and Spec health. Every row deep-links to its
  # detail pane via a `#unit-…` URL fragment, and the filter input narrows the
  # subject rows. Queue navigation, current-selection marking, and j/k keys
  # are wired in the page JS.
  @queue_group_labels %{
    spec_edited: "Spec edited",
    code_only: "Code only",
    impacted_only: "Impacted only"
  }

  defp render_queue(view) do
    sev_by_id =
      Map.new(view.affected_subjects, fn s -> {s.id, worst_finding_severity(s.findings)} end)

    files_by_id = Map.new(view.affected_subjects, fn s -> {s.id, length(s.changed_files)} end)
    kind_by_id = Map.new(view.affected_subjects, fn s -> {s.id, s.change_kind} end)

    [
      ~S|<input type="text" class="queue-filter" placeholder="Filter subjects…" aria-label="Filter review queue">|,
      ~S|<nav aria-label="Review units"><ul class="queue-list">|,
      queue_item("overview", "Overview", ""),
      queue_item(
        "decisions",
        ~s|Decisions changed <span class="queue-count">#{length(view.decisions_changed)}</span>|,
        ""
      ),
      render_queue_subjects(view.queue_subjects, sev_by_id, files_by_id, kind_by_id),
      queue_item(
        "misc",
        ~s|Outside the spec system <span class="queue-count">#{length(view.unmapped_changes)}</span>|,
        ""
      ),
      queue_item("files", "All files", ""),
      queue_item("health", "Spec health", spec_health_queue_badge(view.triage)),
      ~S|</ul></nav>|
    ]
  end

  defp queue_item(unit, label, trailing) do
    ~s|<li class="queue-item" data-unit="#{unit}"><a class="queue-link" href="#unit-#{unit}">#{label}#{trailing}</a></li>|
  end

  defp render_queue_subjects([], _sev, _files, _kind), do: ""

  defp render_queue_subjects(queue_subjects, sev_by_id, files_by_id, kind_by_id) do
    queue_subjects
    |> Enum.chunk_by(& &1.change_kind)
    |> Enum.map(fn [%{change_kind: kind} | _] = chunk ->
      [
        ~s|<li class="queue-group-label">#{h(Map.get(@queue_group_labels, kind, to_string(kind)))}</li>|,
        Enum.map(chunk, fn e ->
          render_queue_subject_row(
            e,
            Map.get(sev_by_id, e.id),
            Map.get(files_by_id, e.id, 0),
            Map.get(kind_by_id, e.id, e.change_kind)
          )
        end)
      ]
    end)
  end

  defp render_queue_subject_row(entry, severity, file_count, change_kind) do
    dot =
      case severity do
        nil ->
          ~S|<span class="queue-dot queue-dot-none" aria-hidden="true"></span>|

        sev ->
          ~s|<span class="queue-dot queue-dot-#{sev}" title="#{h(sev)} finding#{maybe_s(entry.findings_count)}"></span>|
      end

    spec_chip =
      if change_kind == :spec_edited do
        ~S|<span class="queue-chip queue-chip-spec" title="Spec file edited in this change set">SPEC</span>|
      else
        ""
      end

    ~s|<li class="queue-item queue-subject" data-unit="subject-#{slug(entry.id)}" data-subject-id="#{h(entry.id)}"><a class="queue-link" href="#unit-subject-#{slug(entry.id)}">#{dot}<code class="queue-subject-id">#{h(entry.id)}</code>#{spec_chip}<span class="queue-filecount">#{file_count} file#{maybe_s(file_count)}</span></a></li>|
  end

  defp spec_health_queue_badge(triage) do
    if degraded?(triage) do
      ~S| <span class="queue-badge queue-badge-degraded" title="Verification is partial — some legs could not be checked">partial</span>|
    else
      ""
    end
  end

  defp degraded?(triage) do
    triage
    |> Map.get(:detector_unavailable_by_leg, %{})
    |> map_size() > 0
  end

  defp worst_finding_severity([]), do: nil

  defp worst_finding_severity(findings) do
    severities = Enum.map(findings, & &1["severity"])

    cond do
      "error" in severities -> "error"
      "warning" in severities -> "warning"
      "info" in severities -> "info"
      true -> nil
    end
  end

  # covers: specled.spec_review.triage_panel
  # A persistent change-verdict chip lives in the top bar and states the
  # change-scoped verdict — the count/severity of findings the change set
  # introduced, or a clean confirmation when it introduces none. The chip is
  # driven by the differential verdict only, so a change that introduces
  # nothing reads clean even when pre-existing findings or degraded
  # verification exist at head.
  @doc false
  def render_verdict_chip(%{change_verdict: verdict}), do: render_verdict_chip(verdict)

  def render_verdict_chip(%{differential?: false}) do
    ~S|<span class="verdict-chip verdict-chip-nondiff" title="No committed base state — findings could not be attributed to this change">No base attribution</span>|
  end

  def render_verdict_chip(%{clean?: true}) do
    ~S|<span class="verdict-chip verdict-chip-clean" title="This change set introduces no findings">✓ Clean — no findings introduced</span>|
  end

  def render_verdict_chip(%{introduced_count: count, by_severity: by_sev}) do
    sev = worst_severity_key(by_sev)

    ~s|<span class="verdict-chip verdict-chip-#{sev}" title="This change set introduces #{count} finding#{maybe_s(count)}">#{count} finding#{maybe_s(count)} introduced</span>|
  end

  def render_verdict_chip(_), do: ""

  defp worst_severity_key(by_sev) do
    cond do
      Map.get(by_sev, "error", 0) > 0 -> "error"
      Map.get(by_sev, "warning", 0) > 0 -> "warning"
      true -> "info"
    end
  end

  # covers: specled.spec_review.theme_tokens
  # A three-state theme control (system / light / dark) in the top bar. The
  # choice is applied and persisted to localStorage by the page JS; the
  # inline bootstrap script in <head> applies any stored choice before first
  # paint so there is no flash. No network resources are involved.
  @doc false
  def render_theme_toggle do
    ~S"""
    <div class="theme-toggle" role="group" aria-label="Theme">
      <button type="button" class="theme-btn" data-theme-choice="system" title="Match system">◐</button>
      <button type="button" class="theme-btn" data-theme-choice="light" title="Light">☀</button>
      <button type="button" class="theme-btn" data-theme-choice="dark" title="Dark">☾</button>
    </div>
    """
  end

  # covers: specled.spec_review.change_scoped_overview
  # The Overview (landing) pane is change-scoped only: the change verdict, the
  # diff-scoped counts, the spec edits, the differential findings delta, the
  # file breakdown, and the changed decisions. Whole-repo inventories and the
  # sync triangle are deliberately absent here — they live on Spec health.
  defp render_overview(view) do
    [
      ~s|<section class="overview" aria-label="Change overview">|,
      render_overview_headline(view.findings_delta),
      render_overview_tiles(view),
      render_overview_findings(view.findings_delta, view.all_findings),
      render_overview_spec_edits(view.affected_subjects),
      render_overview_file_breakdown(view.file_breakdown),
      render_overview_decisions(view.decisions_changed),
      ~S|</section>|
    ]
  end

  defp render_overview_headline(%{change_verdict: %{differential?: false}}) do
    ~S|<div class="overview-headline overview-headline-nondiff"><h2>Findings could not be attributed to this change.</h2><p>No committed <code>.spec/state.json</code> at the base ref, so findings below are shown for the head ref as a whole rather than as introduced by this change set.</p></div>|
  end

  defp render_overview_headline(%{change_verdict: %{clean?: true}}) do
    ~S|<div class="overview-headline overview-headline-clean"><h2>✓ This change introduces no findings.</h2><p>Pre-existing repo state, if any, is on the <a class="queue-link" href="#unit-health">Spec health</a> pane and does not affect this change's verdict.</p></div>|
  end

  defp render_overview_headline(%{
         change_verdict: %{introduced_count: count, by_severity: by_sev}
       }) do
    chips =
      ["error", "warning", "info"]
      |> Enum.map(fn sev ->
        case Map.get(by_sev, sev, 0) do
          0 -> ""
          n -> ~s|<span class="overview-sev overview-sev-#{sev}">#{n} #{sev}</span>|
        end
      end)

    ~s|<div class="overview-headline overview-headline-flagged"><h2>This change introduces #{count} finding#{maybe_s(count)}.</h2><p class="overview-sev-row">#{chips}</p></div>|
  end

  defp render_overview_headline(_), do: ""

  defp render_overview_tiles(view) do
    spec_reqs_edited =
      view.affected_subjects
      |> Enum.map(fn s ->
        r = s.spec_changes.requirements
        length(r.added) + length(r.modified) + length(r.removed)
      end)
      |> Enum.sum()

    tiles = [
      {"Subjects touched", length(view.affected_subjects)},
      {"Spec requirements edited", spec_reqs_edited},
      {"Decisions changed", length(view.decisions_changed)},
      {"Unmapped files", view.file_breakdown.unmapped}
    ]

    [
      ~S|<div class="overview-tiles">|,
      Enum.map(tiles, fn {label, n} ->
        ~s|<div class="overview-tile"><span class="overview-tile-num">#{n}</span><span class="overview-tile-label">#{h(label)}</span></div>|
      end),
      ~S|</div>|
    ]
  end

  # covers: specled.spec_review.findings_delta
  # The Overview classifies findings differentially — introduced / resolved /
  # pre-existing — from the S1 view-model's `findings_delta`. When base
  # attribution is unavailable the pane renders a single explicitly-labeled
  # non-differential digest instead, never presenting findings as introduced.
  defp render_overview_findings(%{delta_available?: false}, all_findings) do
    case render_findings_digest(all_findings) do
      "" ->
        ""

      digest ->
        [
          ~S|<section class="overview-findings" aria-label="Findings (no base attribution)">|,
          ~S|<h3 class="overview-section-heading">Findings <span class="overview-nondiff-note">(not attributed to this change — no base state)</span></h3>|,
          digest,
          ~S|</section>|
        ]
    end
  end

  defp render_overview_findings(delta, _all_findings) do
    sections =
      [
        {"Introduced by this change", "introduced", delta.introduced},
        {"Resolved by this change", "resolved", delta.resolved},
        {"Pre-existing (not caused by this change)", "pre-existing", delta.pre_existing}
      ]
      |> Enum.map(fn {label, cls, findings} ->
        case render_findings_digest(findings) do
          "" ->
            ""

          digest ->
            [
              ~s|<div class="overview-delta-group overview-delta-#{cls}">|,
              ~s|<h4 class="overview-delta-heading">#{h(label)} <span class="overview-delta-count">#{length(findings)}</span></h4>|,
              digest,
              ~S|</div>|
            ]
        end
      end)

    if delta.introduced == [] and delta.resolved == [] and delta.pre_existing == [] do
      ""
    else
      [
        ~S|<section class="overview-findings" aria-label="Findings delta">|,
        ~S|<h3 class="overview-section-heading">Findings delta</h3>|,
        sections,
        ~S|</section>|
      ]
    end
  end

  defp render_overview_spec_edits(affected_subjects) do
    edited =
      Enum.filter(affected_subjects, fn s ->
        r = s.spec_changes.requirements
        sc = s.spec_changes.scenarios

        r.added != [] or r.modified != [] or r.removed != [] or
          sc.added != [] or sc.modified != [] or sc.removed != []
      end)

    case edited do
      [] ->
        ""

      _ ->
        [
          ~S|<section class="overview-spec-edits" aria-label="Spec edits"><h3 class="overview-section-heading">Spec edits in this change</h3>|,
          ~S|<ul class="overview-spec-edits-list">|,
          Enum.map(edited, fn s ->
            r = s.spec_changes.requirements

            ~s|<li><a class="queue-link" href="#unit-subject-#{slug(s.id)}"><code>#{h(s.id)}</code></a> <span class="overview-spec-edit-counts">+#{length(r.added)} added · ~#{length(r.modified)} modified · -#{length(r.removed)} removed</span></li>|
          end),
          ~S|</ul></section>|
        ]
    end
  end

  defp render_overview_file_breakdown(%{total: 0}), do: ""

  defp render_overview_file_breakdown(%{total: total} = b) do
    seg = fn n, cls, label ->
      if n == 0 do
        ""
      else
        pct = Float.round(n / total * 100, 1)

        ~s|<div class="overview-meter-seg overview-meter-#{cls}" style="flex: #{n}" title="#{n} #{label} (#{pct}%)"></div>|
      end
    end

    [
      ~S|<section class="overview-file-breakdown" aria-label="File breakdown"><h3 class="overview-section-heading">File breakdown</h3>|,
      ~S|<div class="overview-meter">|,
      seg.(b.mapped, "mapped", "mapped to a subject"),
      seg.(b.policy, "policy", "spec/policy files"),
      seg.(b.unmapped, "unmapped", "unmapped"),
      ~S|</div>|,
      ~s|<ul class="overview-meter-legend"><li><span class="overview-meter-key overview-meter-mapped"></span>#{b.mapped} mapped</li><li><span class="overview-meter-key overview-meter-policy"></span>#{b.policy} spec/policy</li><li><span class="overview-meter-key overview-meter-unmapped"></span>#{b.unmapped} unmapped</li></ul>|,
      ~S|</section>|
    ]
  end

  defp render_overview_decisions([]), do: ""

  defp render_overview_decisions(decisions) do
    [
      ~S|<section class="overview-decisions" aria-label="Decisions changed"><h3 class="overview-section-heading">Decisions changed <span class="queue-count">|,
      Integer.to_string(length(decisions)),
      ~S|</span></h3><ul class="overview-decisions-list">|,
      Enum.map(decisions, fn d ->
        label = d.id || Path.basename(d.file || "")
        ~s|<li><code>#{h(label)}</code></li>|
      end),
      ~s|</ul><p class="overview-decisions-more"><a class="queue-link" href="#unit-decisions">Open Decisions changed →</a></p></section>|
    ]
  end

  # covers: specled.spec_review.repo_state_health_pane
  # Whole-repo verification state renders here and nowhere else: the sync
  # triangle with per-leg states, the per-leg check lists, the strength
  # inventory, and the full findings inventory. The heading explicitly labels
  # the content as repo state at the head ref so it is never mistaken for the
  # change set's own verdict.
  defp render_spec_health(view) do
    triage = view.triage

    [
      ~s|<section class="spec-health" aria-label="Spec health">|,
      ~s|<header class="spec-health-head"><h2>Spec health <span class="spec-health-scope">— repo state at <code>#{h(view.meta.head_ref)}</code></span></h2>|,
      ~S|<p class="spec-health-note">This is the whole-repo verification state at the head ref, not the verdict for this change set. It gates <code>mix spec.check</code> regardless of what this PR touched.</p>|,
      spec_health_partial_note(triage),
      ~S|</header>|,
      render_sync_headline(triage),
      render_sync_checklist(triage),
      render_strength_inventory(triage),
      render_repo_inventory(triage),
      render_health_findings_inventory(view.all_findings),
      render_coverage_help_disclosure(),
      ~S|</section>|
    ]
  end

  defp spec_health_partial_note(triage) do
    if degraded?(triage) do
      ~S|<p class="spec-health-partial" role="status">Verification is partial on this run — one or more triangle legs could not be checked. See the degraded legs below.</p>|
    else
      ""
    end
  end

  defp render_strength_inventory(%{strength_breakdown: breakdown})
       when is_map(breakdown) and map_size(breakdown) > 0 do
    order = [:executed, :linked, :claimed, :uncovered]

    rows =
      order
      |> Enum.map(fn s -> {s, Map.get(breakdown, s, 0)} end)
      |> Enum.reject(fn {_s, n} -> n == 0 end)

    [
      ~S|<section class="strength-inventory" aria-label="Coverage strength inventory"><h3 class="section-heading">Coverage strength (repo state)</h3><ul class="strength-inventory-list">|,
      Enum.map(rows, fn {s, n} ->
        ~s|<li><span class="strength-inventory-key strength-#{s}">#{h(to_string(s))}</span><span class="strength-inventory-count">#{n}</span></li>|
      end),
      ~S|</ul></section>|
    ]
  end

  defp render_strength_inventory(_), do: ""

  defp render_repo_inventory(triage) do
    items = [
      {"Requirements", Map.get(triage, :requirement_count, 0)},
      {"Bindings", Map.get(triage, :binding_count, 0)},
      {"Verification entries", Map.get(triage, :verification_count, 0)},
      {"ADR references", Map.get(triage, :adr_ref_count, 0)}
    ]

    [
      ~S|<section class="repo-inventory" aria-label="Repo inventory"><h3 class="section-heading">Inventory (repo state)</h3><ul class="repo-inventory-list">|,
      Enum.map(items, fn {label, n} ->
        ~s|<li><span class="repo-inventory-count">#{n}</span> <span class="repo-inventory-label">#{h(label)}</span></li>|
      end),
      ~S|</ul></section>|
    ]
  end

  defp render_health_findings_inventory(all_findings) do
    case render_findings_digest(all_findings) do
      "" ->
        ~S|<section class="health-findings" aria-label="Findings inventory"><h3 class="section-heading">Findings inventory (repo state)</h3><p class="health-findings-empty">No findings at head.</p></section>|

      digest ->
        [
          ~s|<section class="health-findings" aria-label="Findings inventory"><h3 class="section-heading">Findings inventory (repo state · #{length(all_findings)})</h3>|,
          digest,
          ~S|</section>|
        ]
    end
  end

  # covers: specled.spec_review.findings_digest_dedup
  # Findings on the Overview and Spec health panes are grouped by (code,
  # reason) into a single digest row carrying the severity, the occurrence
  # count, and an expandable list of the affected subjects linking to their
  # queue entries — never one visually identical row per finding instance.
  @doc false
  def render_findings_digest([]), do: ""

  def render_findings_digest(findings) do
    groups =
      findings
      |> Enum.group_by(fn f -> {f["code"], f["reason"]} end)
      |> Enum.map(fn {{code, reason}, items} ->
        %{
          code: code,
          reason: reason,
          count: length(items),
          severity: worst_finding_severity(items) || "info",
          subjects:
            items
            |> Enum.map(& &1["subject_id"])
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()
        }
      end)
      |> Enum.sort_by(fn g -> {severity_rank(g.severity), -g.count, to_string(g.code)} end)

    [
      ~S|<ul class="findings-digest">|,
      Enum.map(groups, &render_findings_digest_row/1),
      ~S|</ul>|
    ]
  end

  defp render_findings_digest_row(g) do
    reason_frag =
      if g.reason, do: ~s| <span class="findings-digest-reason">#{h(g.reason)}</span>|, else: ""

    subjects_frag =
      case g.subjects do
        [] ->
          ""

        subjects ->
          links =
            Enum.map_join(subjects, "", fn sid ->
              ~s|<li><a class="queue-link" href="#unit-subject-#{slug(sid)}"><code>#{h(sid)}</code></a></li>|
            end)

          ~s|<details class="findings-digest-subjects"><summary>#{length(subjects)} subject#{maybe_s(length(subjects))}</summary><ul>#{links}</ul></details>|
      end

    ~s|<li class="findings-digest-row findings-digest-#{g.severity}"><div class="findings-digest-main"><span class="findings-digest-sev findings-group-sev-#{g.severity}"#{title_attr(tooltip(:severity, g.severity))}>#{h(g.severity)}</span><code class="findings-digest-code">#{h(g.code)}</code>#{reason_frag}<span class="findings-digest-count">×#{g.count}</span></div>#{subjects_frag}</li>|
  end

  defp severity_rank("error"), do: 0
  defp severity_rank("warning"), do: 1
  defp severity_rank("info"), do: 2
  defp severity_rank(_), do: 3

  # Findings above info severity are real failures; an info-only finding set
  # (e.g. a lone `detector_unavailable` advisory) must not read as "Out of
  # sync ⚠" — that contradicts the Overview's own "advisory; never blocks"
  # framing and the decision record's "degraded ≠ warning" principle.
  defp sync_status(triage) do
    blocking_count =
      triage.by_severity
      |> Map.drop(["info"])
      |> Map.values()
      |> Enum.sum()

    cond do
      triage.findings_count == 0 -> :in_sync
      blocking_count > 0 -> :out_of_sync
      true -> :advisory_only
    end
  end

  defp render_sync_headline(triage) do
    status = sync_status(triage)

    {icon, icon_class, title} =
      case status do
        :in_sync ->
          {"✓", "sync-headline-icon-ok", "In sync"}

        :advisory_only ->
          {"?", "sync-headline-icon-advisory",
           "Cannot fully verify — #{triage.findings_count} advisory finding#{maybe_s(triage.findings_count)}"}

        :out_of_sync ->
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
      #{render_sync_diagram(triage, status == :in_sync)}
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
      leg_state(
        fbc,
        spec_to_code_codes,
        triage.binding_count == 0,
        map_size(spec_to_code_degraded) > 0
      )

    code_to_tests_state =
      leg_state(
        fbc,
        code_to_tests_codes,
        triage.binding_count == 0,
        map_size(spec_to_tests_degraded) > 0
      )

    tests_to_coverage_state =
      leg_state(
        fbc,
        tests_to_coverage_codes,
        triage.verification_count == 0,
        map_size(tests_to_coverage_degraded) > 0
      )

    nodes = [
      {"SPEC",
       "#{triage.affected_subject_count} subj · #{triage.requirement_count} req#{maybe_s(triage.requirement_count)}",
       triage.requirement_count == 0,
       "Requirements declared in your subject .spec.md files. Each is a normative claim the rest of the chain must back up."},
      {"CODE", "#{triage.binding_count} MFA#{maybe_s(triage.binding_count)}",
       triage.binding_count == 0,
       "Functions named in each subject's realized_by block. Specled checks they actually exist as exported functions in the codebase. \"0 MFAs\" means no affected subject declared a realized_by — there's nothing to verify on this leg, neither pass nor fail."},
      {"TESTS",
       "#{triage.verification_count} verif#{if triage.verification_count == 1, do: "", else: "s"}",
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
        codes: ~w(
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
        label:
          "Every <code>realized_by</code> surface and verification target file actually exists",
        codes:
          ~w(surface_target_missing verification_target_missing verification_target_missing_file),
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
        label:
          "Every <code>must</code> requirement under <code>tagged_tests</code> has a matching <code>@tag spec:</code>",
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
        codes: ~w(
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
        codes:
          ~w(branch_guard_missing_subject_update branch_guard_missing_decision_update branch_guard_unmapped_change),
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

  defp maybe_plural(1, word), do: word
  defp maybe_plural(_, word), do: word <> "s"

  defp maybe_s(1), do: ""
  defp maybe_s(_), do: "s"

  @doc false
  def render_findings_list([]), do: ""

  # covers: specled.spec_review.triage_panel
  # Group findings by triangle leg, then by severity within each leg, so a
  # busy PR's flat list becomes scannable. The leg classifier reuses the
  # code-to-leg mapping that drives the sync checklist (build_sync_checks)
  # rather than maintaining a parallel table.
  def render_findings_list(findings) do
    grouped = group_findings_by_leg(findings)
    total = length(findings)

    [
      ~s|<details class="findings-list" open>|,
      ~s|<summary>All findings (#{total})</summary>|,
      Enum.map(grouped, &render_findings_group/1),
      ~S|</details>|
    ]
  end

  # The canonical leg buckets for the global findings list. Order matters —
  # this is the order groups appear in the rendered list.
  @findings_leg_order [
    "Spec well-formed",
    "Spec ↔ Code",
    "Spec ↔ Tests",
    "Code ↔ Tests",
    "Coverage",
    "Decisions",
    "Branch",
    "Other"
  ]

  # Severity ordering within a group: errors first, warnings, info, then the
  # rest. Findings without a severity sort to the end.
  @severity_order ~w(error warning info)

  @doc false
  def group_findings_by_leg(findings) do
    by_leg =
      Enum.reduce(findings, %{}, fn f, acc ->
        leg = leg_for_finding_code(f["code"])
        Map.update(acc, leg, [f], &[f | &1])
      end)

    @findings_leg_order
    |> Enum.flat_map(fn leg ->
      case Map.get(by_leg, leg) do
        nil -> []
        items -> [{leg, sort_findings_by_severity(Enum.reverse(items))}]
      end
    end)
  end

  # covers: specled.spec_review.triangle_code_classification
  # Map a finding code to its triangle leg by reusing the code-to-leg
  # mapping that already lives in build_sync_checks (the sync checklist's
  # source of truth, added by the triangle-code classifier work). Codes
  # the checklist does not classify fall into the "Other" bucket, which
  # still groups them at the bottom of the list.
  @doc false
  def leg_for_finding_code(code) when is_binary(code) do
    Map.get(code_to_leg_lookup(), code, "Other")
  end

  def leg_for_finding_code(_), do: "Other"

  # Walk build_sync_checks (with a zeroed triage — only `codes` and `leg`
  # matter for the lookup) and project each row's code list onto its leg
  # bucket. The first row to claim a code wins, which mirrors the order
  # that build_sync_checks emits. The detailed sync-check `leg` labels
  # ("Tests → Coverage", "Spec → Decisions", "Decisions / governance",
  # ...) are normalized to the seven public buckets used by this list.
  @doc false
  def code_to_leg_lookup do
    zeroed_triage = %{
      findings_by_code: %{},
      affected_subject_count: 0,
      binding_count: 0,
      requirement_count: 0,
      verification_count: 0,
      adr_ref_count: 0,
      strength_breakdown: %{}
    }

    zeroed_triage
    |> build_sync_checks()
    |> Enum.flat_map(fn check ->
      bucket = sync_check_leg_to_bucket(check.leg)
      Enum.map(check.codes, fn code -> {code, bucket} end)
    end)
    |> Enum.reduce(%{}, fn {code, bucket}, acc ->
      Map.put_new(acc, code, bucket)
    end)
  end

  # Normalize the detailed sync-check leg labels to the seven public
  # buckets used by the global findings list. This is the one place where
  # the public group vocabulary differs from the internal sync-check
  # vocabulary.
  defp sync_check_leg_to_bucket("Spec"), do: "Spec well-formed"
  defp sync_check_leg_to_bucket("Spec → Code"), do: "Spec ↔ Code"
  defp sync_check_leg_to_bucket("Spec → Tests"), do: "Spec ↔ Tests"
  defp sync_check_leg_to_bucket("Code → Tests"), do: "Code ↔ Tests"
  defp sync_check_leg_to_bucket("Tests → Coverage"), do: "Coverage"
  defp sync_check_leg_to_bucket("Coverage"), do: "Coverage"
  defp sync_check_leg_to_bucket("Spec → Decisions"), do: "Decisions"
  defp sync_check_leg_to_bucket("Decisions / governance"), do: "Decisions"
  defp sync_check_leg_to_bucket("Branch"), do: "Branch"
  defp sync_check_leg_to_bucket(_), do: "Other"

  defp sort_findings_by_severity(findings) do
    Enum.sort_by(findings, fn f ->
      sev = f["severity"] || ""

      case Enum.find_index(@severity_order, &(&1 == sev)) do
        nil -> length(@severity_order)
        idx -> idx
      end
    end)
  end

  defp render_findings_group({leg, findings}) do
    counts = severity_counts(findings)
    total = length(findings)

    [
      ~s|<div class="findings-group" data-leg="#{h(leg)}">|,
      ~s|<h3 class="findings-group-heading">|,
      ~s|<span class="findings-group-leg">#{h(leg)}</span>|,
      ~s| <span class="findings-group-count">#{total} #{maybe_plural(total, "finding")}</span>|,
      render_findings_group_severity_chips(counts),
      ~S|</h3>|,
      ~s|<ul class="findings-group-list">|,
      Enum.map(findings, &render_finding_item/1),
      ~S|</ul>|,
      ~S|</div>|
    ]
  end

  defp render_findings_group_severity_chips(counts) do
    @severity_order
    |> Enum.map(fn sev ->
      case Map.get(counts, sev, 0) do
        0 ->
          ""

        n ->
          ~s| <span class="findings-group-sev findings-group-sev-#{h(sev)}"#{title_attr(tooltip(:severity, sev))}>#{n} #{h(sev)}</span>|
      end
    end)
  end

  defp severity_counts(findings) do
    Enum.reduce(findings, %{}, fn f, acc ->
      sev = f["severity"] || ""
      Map.update(acc, sev, 1, &(&1 + 1))
    end)
  end

  defp render_finding_item(f) do
    sev = f["severity"] || ""

    ~s"""
        <li class="finding-item finding-#{h(sev)}">
          <span class="finding-severity"#{title_attr(tooltip(:severity, sev))}>#{h(sev)}</span>
          <span class="finding-code">#{h(f["code"])}</span>
          #{render_subject_link(f)}
          <span class="finding-message">#{h(f["message"])}</span>
        </li>
    """
  end

  # Render the subject anchor(s) shown in the All-findings row.
  #
  # For most finding codes the `subject_id` IS the subject the reviewer should
  # follow, so we render a single anchor. For `branch_guard_untethered_test`,
  # though, `subject_id` is the *claimed* subject (the one the test's `@tag
  # spec:` named) while the test's coverage actually exercises a different
  # subject — the `observed_owners` list. Linking only to the claimed subject
  # sends the reviewer to a card with no evidence of the misalignment. We
  # surface both: "claims A, hits B" with both names anchored, so the headline
  # IS the misalignment.
  defp render_subject_link(nil), do: ""

  defp render_subject_link(%{"code" => "branch_guard_untethered_test"} = finding) do
    claimed = finding["subject_id"]
    observed = List.wrap(finding["observed_owners"]) |> Enum.reject(&is_nil/1)

    case {claimed, observed} do
      {nil, []} ->
        ""

      {nil, _} ->
        # No claimed subject (shouldn't happen in practice, but render safely).
        render_subject_anchors(observed)

      {_, []} ->
        # No observed owners recorded — fall back to the single claimed link.
        render_subject_anchor(claimed)

      {_, _} ->
        ~s|<span class="finding-subject-pair">| <>
          ~s|<span class="finding-subject-label">claims</span> | <>
          render_subject_anchor(claimed) <>
          ~s|<span class="finding-subject-label">, hits</span> | <>
          render_subject_anchors(observed) <>
          ~s|</span>|
    end
  end

  defp render_subject_link(%{"subject_id" => subject_id}), do: render_subject_link(subject_id)

  defp render_subject_link(finding) when is_map(finding) do
    render_subject_link(Map.get(finding, "subject_id"))
  end

  defp render_subject_link(subject_id) when is_binary(subject_id) do
    render_subject_anchor(subject_id)
  end

  defp render_subject_link(_), do: ""

  defp render_subject_anchor(subject_id) when is_binary(subject_id) do
    ~s|<a class="finding-subject" href="#subject-#{slug(subject_id)}">#{h(subject_id)}</a>|
  end

  defp render_subject_anchor(_), do: ""

  defp render_subject_anchors(subject_ids) do
    subject_ids
    |> Enum.map(&render_subject_anchor/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.intersperse(", ")
    |> Enum.join("")
  end

  # covers: specled.spec_review.review_queue_navigation
  # Each affected subject becomes its own detail pane in the master–detail
  # layout, addressable by the `unit-subject-<slug>` fragment its queue row
  # links to. Exactly one pane is visible at a time (CSS + queue JS); the
  # subject `<article>` keeps its `subject-<slug>` id so inline finding
  # anchors still resolve to it inside the pane.
  defp render_subject_panes(subjects, adrs) do
    Enum.map(subjects, fn s ->
      [
        ~s|<section class="detail-pane" data-unit="subject-#{slug(s.id)}" id="unit-subject-#{slug(s.id)}" tabindex="-1">|,
        render_subject(s, adrs),
        render_subject_raw_verification(s),
        ~S|</section>|
      ]
    end)
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
        <%= SpecLedEx.Review.Html.render_subject_statement(assigns[:s].statement, assigns[:slug]) %>
        <div class="subject-meta-row">
          <code class="subject-id"><%= SpecLedEx.Review.Html.h(assigns[:s].id) %></code>
          <%= if assigns[:s].file do %>
            <span class="subject-file"><%= SpecLedEx.Review.Html.h(assigns[:s].file) %></span>
          <% end %>
          <%= SpecLedEx.Review.Html.render_subject_change_badge(assigns[:s].spec_changes) %>
          <%= SpecLedEx.Review.Html.render_subject_finding_badges(assigns[:s].findings) %>
          <%= SpecLedEx.Review.Html.render_subject_binding_health(assigns[:s].bindings, assigns[:s].findings) %>
        </div>
        <%= SpecLedEx.Review.Html.render_subject_leg_chips(assigns[:s].findings) %>
      </header>
      <%= SpecLedEx.Review.Html.render_subject_pivots(assigns[:s], assigns[:slug], assigns[:adrs]) %>
    </article>
    """
  end

  # covers: specled.spec_review.per_subject_tabs
  # Render the four per-subject pivots (Spec / Code / Coverage / Decisions) with
  # change-scoped labels, a smart default (the pivot carrying this change set's
  # edits: Code when code changed, else Spec), and empty pivots visibly
  # de-emphasized with the reason exposed as a tooltip. Centralized here (rather
  # than inline in the EEx template) so the label/default/de-emphasis logic is
  # unit-testable and the template stays declarative.
  @doc false
  def render_subject_pivots(s, slug, adrs) do
    default = default_pivot(s)

    pivots = [
      {:spec, "spec-" <> slug, spec_tab_label(s), spec_empty_reason(s), render_spec_tab(s)},
      {:code, "code-" <> slug, code_tab_label(s), code_empty_reason(s), render_code_tab(s)},
      {:coverage, "coverage-" <> slug, coverage_tab_label(s), coverage_empty_reason(s),
       render_coverage_tab(s)},
      {:decisions, "decisions-" <> slug, decisions_tab_label(s), decisions_empty_reason(s),
       render_decisions_tab(s, adrs)}
    ]

    [
      ~S|<div class="tabs" role="tablist">|,
      Enum.map(pivots, fn {key, target, label, empty_reason, _panel} ->
        active = if key == default, do: " active", else: ""
        empty = if empty_reason, do: " tab-empty", else: ""

        ~s|<button class="tab#{active}#{empty}" role="tab" data-tab="#{target}"#{title_attr(empty_reason)}>#{label}</button>|
      end),
      ~S|</div>|,
      ~S|<div class="tab-panels">|,
      Enum.map(pivots, fn {key, target, _label, _reason, panel} ->
        active = if key == default, do: " active", else: ""

        [
          ~s|<section class="tab-panel#{active}" id="#{target}" role="tabpanel">|,
          panel,
          ~S|</section>|
        ]
      end),
      ~S|</div>|
    ]
  end

  # The default-selected pivot follows the change: Code when this subject's code
  # changed, Spec when only the spec was edited, otherwise the first pivot that
  # actually has content (an impacted-only subject with no direct edits).
  defp default_pivot(s) do
    cond do
      Map.get(s, :code_changes, []) != [] -> :code
      spec_edited?(s) -> :spec
      is_nil(spec_empty_reason(s)) -> :spec
      is_nil(coverage_empty_reason(s)) -> :coverage
      is_nil(decisions_empty_reason(s)) -> :decisions
      true -> :spec
    end
  end

  defp spec_edited?(s) do
    case Map.get(s, :spec_changes) do
      %{} = changes ->
        Map.get(changes, :file_changed?, false) or Map.get(changes, :base_existed?, true) == false

      _ ->
        false
    end
  end

  defp code_tab_label(s) do
    case Map.get(s, :code_changes, []) do
      [] ->
        "Code"

      changes ->
        n = length(changes)
        "Code · #{n} #{maybe_plural(n, "file")}#{diffstat_suffix(Map.get(s, :diffstat))}"
    end
  end

  defp diffstat_suffix(%{adds: a, dels: d}) when a > 0 or d > 0, do: " +#{a}/−#{d}"
  defp diffstat_suffix(_), do: ""

  defp spec_tab_label(s) do
    case Map.get(s, :spec_changes) do
      %{base_existed?: false} ->
        "Spec · new"

      %{requirements: %{added: added, modified: modified}} ->
        cond do
          added == [] and modified == [] -> "Spec · unchanged"
          true -> "Spec · " <> spec_change_counts(length(added), length(modified))
        end

      _ ->
        "Spec · unchanged"
    end
  end

  defp spec_change_counts(added, modified) do
    [
      if(added > 0, do: "+#{added}", else: nil),
      if(modified > 0, do: "~#{modified}", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp coverage_tab_label(s) do
    touched =
      case Map.get(s, :spec_changes) do
        %{requirements: %{added: added, modified: modified}} ->
          length(added) + length(modified)

        _ ->
          0
      end

    if touched == 0, do: "Coverage · no change", else: "Coverage · #{touched} touched"
  end

  defp decisions_tab_label(s) do
    case Map.get(s, :decision_refs, []) do
      [] -> "Decisions"
      refs -> "Decisions · #{length(refs)} #{maybe_plural(length(refs), "ref")}"
    end
  end

  # An empty-reason helper returns a human sentence when the pivot has no
  # content (so the tab is de-emphasized and the reason surfaced), or nil when
  # the pivot carries content.
  defp code_empty_reason(s) do
    if Map.get(s, :code_changes, []) == [],
      do: "No code files in this change set map to this subject.",
      else: nil
  end

  defp spec_empty_reason(s) do
    reqs = Map.get(s, :requirements, [])
    scenarios = Map.get(s, :scenarios, [])

    if reqs == [] and scenarios == [],
      do: "This subject declares no requirements or scenarios.",
      else: nil
  end

  defp coverage_empty_reason(s) do
    if Map.get(s, :requirements, []) == [],
      do: "No requirements to report coverage for.",
      else: nil
  end

  defp decisions_empty_reason(s) do
    if Map.get(s, :decision_refs, []) == [],
      do: "No ADRs referenced by this subject.",
      else: nil
  end

  # covers: specled.spec_review.spec_first_navigation
  # The prose statement is the subject headline. Long statements are clamped to
  # a few lines with a pure-CSS expand toggle (a checkbox + label, no JS) so the
  # headline stays scannable while the full text remains available in-place.
  @doc false
  def render_subject_statement(statement, slug) do
    text = statement || ""

    if String.length(text) > 160 do
      ~s"""
      <div class="subject-statement-wrap">
        <input type="checkbox" class="statement-toggle" id="stmt-#{slug}" />
        <p class="subject-statement subject-statement-clamped">#{h(text)}</p>
        <label class="statement-expand" for="stmt-#{slug}"></label>
      </div>
      """
    else
      ~s|<p class="subject-statement">#{h(text)}</p>|
    end
  end

  # covers: specled.spec_review.per_subject_tabs
  # Per-subject triangle leg chips summarize this subject's SPEC ↔ CODE,
  # SPEC ↔ TESTS, and CODE ↔ TESTS legs at a glance in the header, derived from
  # the subject's own findings (not repo-wide state) so a reviewer sees which
  # leg carries weight before pivoting into a tab. A leg with no finding reads
  # ok (✓); a detector_unavailable finding degrades it (?); an error fails it
  # (✗); a warning flags it (!).
  @doc false
  def render_subject_leg_chips(findings) do
    findings = List.wrap(findings)

    [
      ~s|<div class="subject-legs" aria-label="Triangle leg states for this subject">|,
      Enum.map(["Spec ↔ Code", "Spec ↔ Tests", "Code ↔ Tests"], fn leg ->
        state = subject_leg_state(findings, leg)

        ~s|<span class="leg-chip leg-chip-#{state}"#{title_attr(subject_leg_tooltip(leg, state))}>#{h(leg)} <span class="leg-chip-glyph" aria-hidden="true">#{leg_state_glyph(state)}</span></span>|
      end),
      ~S|</div>|
    ]
  end

  defp subject_leg_state(findings, leg) do
    leg_findings = Enum.filter(findings, fn f -> finding_leg(f) == leg end)

    cond do
      leg_findings == [] -> :ok
      Enum.any?(leg_findings, &(&1["severity"] == "error")) -> :fail
      Enum.any?(leg_findings, &(&1["code"] == "detector_unavailable")) -> :degraded
      Enum.any?(leg_findings, &(&1["severity"] == "warning")) -> :warn
      true -> :degraded
    end
  end

  # A detector_unavailable finding carries no checklist code, so its leg is
  # keyed on its reason (mirroring the view-model's detector_unavailable_by_leg
  # aggregation): no_coverage_artifact lives on CODE ↔ TESTS; every other
  # reason — including no_realized_by and the realization-tier reasons — lives
  # on SPEC ↔ CODE. All other findings defer to the shared code-to-leg lookup.
  defp finding_leg(%{"code" => "detector_unavailable"} = f) do
    case f["reason"] do
      "no_coverage_artifact" -> "Code ↔ Tests"
      _ -> "Spec ↔ Code"
    end
  end

  defp finding_leg(f), do: leg_for_finding_code(f["code"])

  defp leg_state_glyph(:ok), do: "✓"
  defp leg_state_glyph(:degraded), do: "?"
  defp leg_state_glyph(:warn), do: "!"
  defp leg_state_glyph(:fail), do: "✗"

  defp subject_leg_tooltip(leg, :ok), do: "#{leg}: no findings on this leg for this subject."

  defp subject_leg_tooltip(leg, :degraded),
    do: "#{leg}: verification degraded — a detector was unavailable for this leg."

  defp subject_leg_tooltip(leg, :warn), do: "#{leg}: a warning-level finding affects this leg."
  defp subject_leg_tooltip(leg, :fail), do: "#{leg}: a failing finding affects this leg."

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
    base_statements = base_statement_lookup(s.spec_changes.requirements)

    [
      render_spec_change_callout(s.spec_changes, base_existed?),
      render_requirements(s.requirements, s.findings, req_status, base_statements),
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

  # Requirements and scenarios are counted and labeled separately (not
  # summed into one figure) — a merged "N added" collides with the
  # requirements-only counts shown elsewhere (the overview tile, the
  # per-subject spec-edit list, and this tab's own label all count
  # requirements alone), which reads as a data bug rather than two
  # different quantities.
  defp render_spec_change_callout(changes, true) do
    clauses =
      [{"Requirements", changes.requirements}, {"Scenarios", changes.scenarios}]
      |> Enum.map(fn {label, counts} -> {label, spec_change_summary(counts)} end)
      |> Enum.reject(fn {_label, summary} -> summary == "" end)
      |> Enum.map_join(" · ", fn {label, summary} -> "#{label}: #{summary}" end)

    if clauses == "" do
      ""
    else
      ~s"""
      <div class="spec-change-callout">
        <strong>Changes in this PR:</strong> #{clauses}
      </div>
      """
    end
  end

  defp spec_change_summary(%{added: added, modified: modified, removed: removed}) do
    [
      {length(added), "added"},
      {length(modified), "modified"},
      {length(removed), "removed"}
    ]
    |> Enum.reject(fn {n, _} -> n == 0 end)
    |> Enum.map_join(" · ", fn {n, label} -> "#{n} #{label}" end)
  end

  defp render_requirements([], _, _, _), do: ""

  defp render_requirements(requirements, findings, status_lookup, base_statements) do
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

      statement_html =
        if status == :modified do
          render_statement_diff(Map.get(base_statements, id), statement)
        else
          h(statement)
        end

      ~s"""
      <li class="requirement requirement-#{status}">
        <div class="requirement-header">
          #{render_change_chip(status)}
          <code class="requirement-id">#{h(id)}</code>
          <span class="pill pill-priority pill-priority-#{h(priority)}"#{title_attr(tooltip(:priority, priority))}>#{h(priority)}</span>
          <span class="pill pill-neutral"#{title_attr(tooltip(:stability, stability))}>#{h(stability)}</span>
          #{render_requirement_finding_badge(req_findings)}
        </div>
        <p class="requirement-statement">#{statement_html}</p>
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
      [] ->
        "requirement-list"

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

  # Map modified-requirement ids to their base-ref statement so the head
  # rendering can show inline wording del/ins against what was there before.
  defp base_statement_lookup(%{modified: modified}) do
    modified
    |> Enum.map(fn m ->
      id = field(m, :id) || item_id(m)
      base = field(field(m, :base) || %{}, :statement)
      {id, base}
    end)
    |> Enum.reject(fn {id, base} -> id in [nil, ""] or is_nil(base) end)
    |> Map.new()
  end

  defp base_statement_lookup(_), do: %{}

  # Word-level inline diff of a requirement's wording (base -> head) using the
  # stdlib Myers diff over word/whitespace tokens (not graphemes) so a
  # rewritten sentence reads as changed phrases, not a character-level word
  # salad. Two readability guards on top of the raw edit script: short
  # unchanged runs sandwiched between changes are folded into one del/ins
  # pair (avoiding "~~a~~b ~~c~~d ~~e~~f" confetti), and a statement whose
  # wording mostly changed falls back to the old text stacked above the new
  # text — past that point interleaving obscures both sentences.
  # Deterministic and dependency-free. Falls back to the plain head
  # statement when no base wording is available.
  @doc false
  def render_statement_diff(nil, head), do: h(head)

  @rewrite_fallback_ratio 0.55

  def render_statement_diff(base, head) do
    script =
      base
      |> tokenize_words()
      |> List.myers_difference(tokenize_words(head))

    if rewrite_ratio(script) > @rewrite_fallback_ratio do
      ~s|<span class="wording-rewrite"><del class="wording-del wording-block">#{h(base)}</del><ins class="wording-ins wording-block">#{h(head)}</ins></span>|
    else
      script
      |> chunk_edit_script()
      |> coalesce_chunks()
      |> Enum.map(fn
        {:eq, text} ->
          h(text)

        {:change, del, ins} ->
          [
            if(del != "", do: ~s|<del class="wording-del">#{h(del)}</del>|, else: ""),
            if(ins != "", do: ~s|<ins class="wording-ins">#{h(ins)}</ins>|, else: "")
          ]
      end)
    end
  end

  # Share of word tokens (whitespace excluded) that the edit script touches.
  defp rewrite_ratio(script) do
    {changed, total} =
      Enum.reduce(script, {0, 0}, fn {op, tokens}, {changed, total} ->
        words = Enum.count(tokens, &(not whitespace_token?(&1)))
        {changed + if(op == :eq, do: 0, else: words), total + words}
      end)

    if total == 0, do: 0.0, else: changed / total
  end

  # Normalizes the Myers script into `{:eq, text}` and `{:change, del, ins}`
  # chunks by pairing each del run with the ins run that immediately follows.
  defp chunk_edit_script(script) do
    script
    |> Enum.map(fn {op, tokens} -> {op, Enum.join(tokens)} end)
    |> Enum.reduce([], fn
      {:eq, text}, acc -> [{:eq, text} | acc]
      {:del, text}, acc -> [{:change, text, ""} | acc]
      {:ins, text}, [{:change, del, ""} | rest] -> [{:change, del, text} | rest]
      {:ins, text}, acc -> [{:change, "", text} | acc]
    end)
    |> Enum.reverse()
  end

  # An unchanged run of at most one word bridging two changed chunks reads as
  # noise, not signal — fold it into both sides so the change renders as one
  # del/ins pair instead of confetti.
  defp coalesce_chunks(chunks) do
    chunks
    |> Enum.reduce([], fn
      {:change, del2, ins2}, [{:eq, bridge}, {:change, del1, ins1} | rest] ->
        if tiny_bridge?(bridge) do
          [{:change, del1 <> bridge <> del2, ins1 <> bridge <> ins2} | rest]
        else
          [{:change, del2, ins2}, {:eq, bridge}, {:change, del1, ins1} | rest]
        end

      chunk, acc ->
        [chunk | acc]
    end)
    |> Enum.reverse()
  end

  defp tiny_bridge?(text) do
    text |> tokenize_words() |> Enum.count(&(not whitespace_token?(&1))) <= 1
  end

  defp whitespace_token?(token), do: String.trim(token) == ""

  # Splits on whitespace runs while keeping them as their own tokens, so
  # re-joining any subsequence of tokens reconstructs the exact original
  # spacing without an explicit separator.
  defp tokenize_words(text), do: Regex.split(~r/(\s+)/, text, include_captures: true)

  defp render_change_chip(:new),
    do: ~s|<span class="chip chip-new"#{title_attr(tooltip(:change, :new))}>ADDED</span>|

  defp render_change_chip(:modified),
    do:
      ~s|<span class="chip chip-modified"#{title_attr(tooltip(:change, :modified))}>MODIFIED</span>|

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

  # The raw spec file diff is folded away by default — the semantic spec diff
  # (ADDED/MODIFIED/REMOVED requirements and scenarios above, with inline
  # wording del/ins) is the primary read; the line-level file diff is available
  # for reviewers who want the exact hunk.
  defp render_spec_diff(%{file: file, lines: lines}) do
    [
      ~s|<details class="spec-diff-fold">|,
      ~s|<summary class="spec-diff-summary">Raw spec file diff</summary>|,
      ~s|<div class="filename"><code>#{h(file)}</code></div>|,
      render_diff_block(lines, language_for(file)),
      ~S|</details>|
    ]
  end

  # covers: specled.spec_review.per_subject_tabs
  # The Code pivot organizes changes by realized_by binding tier rather than
  # by file path (per_subject_tabs / code_tab_grouped_by_binding). Each changed
  # file is attributed to a tier when one of that tier's declared MFAs names a
  # module whose conventional source file matches the changed file (last module
  # segment underscored == file basename). Files that match no declared binding
  # fall into an "Other changed files" group rather than being dropped, and a
  # subject that declares no bindings at all degrades to a flat file diff with
  # an explanatory note.
  @doc false
  def render_code_tab(%{code_changes: []}) do
    ~S|<p class="empty-tab">No code files in this change set map to this subject.</p>|
  end

  def render_code_tab(%{code_changes: changes} = s) do
    id = Map.get(s, :id, "")
    bindings = normalize_bindings(Map.get(s, :bindings))

    if map_size(bindings) == 0 do
      render_code_flat(changes, id)
    else
      render_code_by_tier(changes, bindings, id)
    end
  end

  defp render_code_flat(changes, id) do
    anchor_prefix = "code-" <> slug(id)
    paths = Enum.map(changes, & &1.file)
    tree = build_path_tree(paths)
    diff_blocks = code_diff_blocks(changes, anchor_prefix)

    [
      ~S|<p class="code-tier-note code-flat-note">This subject declares no <code>realized_by</code> bindings, so changes are shown as a flat file diff rather than grouped by binding tier.</p>|,
      render_files_section(tree, anchor_prefix, "Files (#{length(paths)})", diff_blocks)
    ]
  end

  defp render_code_by_tier(changes, bindings, id) do
    tier_keys = ordered_tier_keys(bindings)
    {grouped, leftover} = assign_changes_to_tiers(changes, tier_keys, bindings)

    [
      Enum.map(tier_keys, fn tier ->
        render_code_tier_group(tier, Map.get(grouped, tier, []), id)
      end),
      render_code_other_group(leftover, id)
    ]
  end

  defp render_code_tier_group(_tier, [], _id), do: ""

  defp render_code_tier_group(tier, changes, id) do
    anchor_prefix = "code-" <> slug(id) <> "-" <> slug(tier)
    label = tier_label(tier)
    paths = Enum.map(changes, & &1.file)
    tree = build_path_tree(paths)
    diff_blocks = code_diff_blocks(changes, anchor_prefix)
    n = length(paths)

    [
      ~s|<div class="code-tier" data-tier="#{h(tier)}">|,
      ~s|<h4 class="code-tier-heading"><span class="code-tier-name">#{h(label)}</span> <span class="code-tier-count">#{n} #{maybe_plural(n, "file")}</span></h4>|,
      render_files_section(tree, anchor_prefix, "#{label} (#{n})", diff_blocks),
      ~S|</div>|
    ]
  end

  defp render_code_other_group([], _id), do: ""

  defp render_code_other_group(changes, id) do
    anchor_prefix = "code-" <> slug(id) <> "-other"
    paths = Enum.map(changes, & &1.file)
    tree = build_path_tree(paths)
    diff_blocks = code_diff_blocks(changes, anchor_prefix)
    n = length(paths)

    [
      ~s|<div class="code-tier code-tier-other" data-tier="other">|,
      ~s|<h4 class="code-tier-heading"><span class="code-tier-name">Other changed files</span> <span class="code-tier-count">#{n} #{maybe_plural(n, "file")}</span></h4>|,
      ~S|<p class="code-tier-note">These files changed in this subject's surface but do not resolve to a declared <code>realized_by</code> binding.</p>|,
      render_files_section(tree, anchor_prefix, "Other files (#{n})", diff_blocks),
      ~S|</div>|
    ]
  end

  defp code_diff_blocks(changes, anchor_prefix) do
    Enum.map(changes, fn %{file: file, lines: lines} ->
      render_file_diff_details(file, lines, anchor_prefix <> "-" <> slug(file))
    end)
  end

  # A file diff renders expanded by default, but a full-file deletion or an
  # oversized diff starts collapsed with a summary note — auto-expanding a
  # 900-line deletion buries every other file in the section.
  @collapse_diff_over_lines 400

  defp render_file_diff_details(file, lines, anchor) do
    changed = Enum.count(lines, fn {kind, _} -> kind in [:add, :del] end)
    deleted? = file_deleted?(lines)

    {open, note} =
      cond do
        deleted? ->
          {"", ~s| <span class="code-change-note">file deleted · #{changed} lines</span>|}

        changed > @collapse_diff_over_lines ->
          {"", ~s| <span class="code-change-note">large diff · #{changed} lines</span>|}

        true ->
          {" open", ""}
      end

    ~s"""
    <details class="code-change" id="#{anchor}"#{open}>
      <summary class="filename"><code>#{h(file)}</code>#{note}</summary>
      #{IO.iodata_to_binary(render_diff_block(lines, language_for(file)))}
    </details>
    """
  end

  defp file_deleted?(lines) do
    Enum.any?(lines, fn
      {:file_header, "deleted file" <> _} -> true
      _ -> false
    end)
  end

  # Normalize a subject's realized_by map to string-keyed tiers with wrapped
  # MFA lists. Bindings arrive from spec-meta as either atom- or string-keyed
  # maps depending on the parse path, so downstream lookups key on strings.
  defp normalize_bindings(bindings) when is_map(bindings) and map_size(bindings) > 0 do
    Map.new(bindings, fn {k, v} -> {to_string(k), List.wrap(v)} end)
  end

  defp normalize_bindings(_), do: %{}

  # api_boundary and implementation are the canonical tiers and lead; any other
  # declared tier follows in alphabetical order for deterministic rendering.
  defp ordered_tier_keys(bindings) do
    keys = Map.keys(bindings)
    preferred = Enum.filter(["api_boundary", "implementation"], &(&1 in keys))
    preferred ++ Enum.sort(keys -- preferred)
  end

  defp assign_changes_to_tiers(changes, tier_keys, bindings) do
    {grouped, leftover} =
      Enum.reduce(changes, {%{}, []}, fn change, {grouped, leftover} ->
        tier =
          Enum.find(tier_keys, fn t ->
            file_matches_tier?(change.file, Map.get(bindings, t, []))
          end)

        case tier do
          nil -> {grouped, [change | leftover]}
          t -> {Map.update(grouped, t, [change], &[change | &1]), leftover}
        end
      end)

    {Map.new(grouped, fn {k, v} -> {k, Enum.reverse(v)} end), Enum.reverse(leftover)}
  end

  defp file_matches_tier?(file, mfas) do
    base = file_basename(file)
    base != "" and Enum.any?(mfas, fn mfa -> mfa_file_basename(mfa) == base end)
  end

  defp file_basename(file) when is_binary(file) do
    file |> Path.basename() |> String.replace(~r/\.exs?$/, "")
  end

  defp file_basename(_), do: ""

  # "SpecLedEx.Realization.ApiBoundary.hash/2" -> "api_boundary" — the
  # conventional Elixir source-file basename for the module named by the MFA.
  # Robust to the app-name vs module-name mismatch (SpecLedEx <-> specled_ex)
  # because it keys on the module's last segment, which matches the file name.
  defp mfa_file_basename(mfa) when is_binary(mfa) do
    mfa
    |> String.split("/")
    |> hd()
    |> String.split(".")
    |> drop_trailing_function()
    |> List.last()
    |> case do
      nil -> ""
      seg -> Macro.underscore(seg)
    end
  end

  defp mfa_file_basename(_), do: ""

  # Drop a single trailing function-name segment (starts lowercase) so only the
  # module segments remain. Bare-module MFAs (e.g. "Mix.Tasks.Spec.Check") have
  # no lowercase tail and are returned unchanged.
  defp drop_trailing_function(segments) do
    case List.last(segments) do
      seg when is_binary(seg) ->
        if seg =~ ~r/^[a-z_]/, do: Enum.drop(segments, -1), else: segments

      _ ->
        segments
    end
  end

  defp tier_label("api_boundary"), do: "API boundary"
  defp tier_label("implementation"), do: "Implementation"

  defp tier_label(tier) do
    tier |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  # covers: specled.spec_review.coverage_pivot_touched_first
  # The Coverage pivot lists requirements the change set touched (added or
  # modified in this subject's spec_changes) first, each carrying its change
  # chip and strength, and folds untouched requirements behind a disclosure
  # whose summary states their strength is unchanged from base. Mirrors the
  # Spec tab's changed-then-unchanged fold with coverage-specific wording.
  @doc false
  def render_coverage_tab(s) do
    closure_reach = Map.get(s, :closure_reach, %{status: :ok, by_requirement: %{}})
    req_status = coverage_req_status(s)

    [
      render_coverage_help_link(),
      render_closure_reach_status(closure_reach),
      render_requirements_coverage(s.requirements, s.claims_by_req, closure_reach, req_status),
      render_bindings_section(s.bindings)
    ]
  end

  # Touched set for the Coverage pivot: requirement ids added or modified by
  # this change set, reusing the Spec tab's id_status_lookup. Defensive —
  # unit-test subjects and code-only changes may carry no spec_changes, in
  # which case every requirement is untouched (folded as unchanged-from-base).
  defp coverage_req_status(s) do
    case Map.get(s, :spec_changes) do
      %{requirements: reqs} -> id_status_lookup(reqs)
      _ -> %{}
    end
  end

  # covers: specled.spec_review.coverage_tab_bind_closure
  # When the tracer manifest or per-test coverage artifact is missing the
  # bind-closure view collapses to a single banner above the requirements
  # list. The top-of-page degraded banner already advertises that the
  # whole report is partial; this status note explains the consequence
  # for the closure summary specifically (so a reader doesn't read empty
  # closure rows as "tests cover nothing").
  @doc false
  def render_closure_reach_status(%{status: :no_coverage_artifact}) do
    ~S"""
    <p class="cov-closure-unavailable" role="status">
      <strong>Coverage artifact unavailable.</strong>
      Per-requirement bind-closure reach cannot be computed without
      <code>.spec/_coverage/per_test.coverdata</code>. Run
      <code>mix spec.cover.test</code> to enable this view.
    </p>
    """
  end

  def render_closure_reach_status(%{status: :no_tracer_manifest}) do
    ~S"""
    <p class="cov-closure-unavailable" role="status">
      <strong>Binding closure unavailable.</strong>
      The compiler tracer manifest is missing, so the realization closure
      cannot be walked. Recompile the project to regenerate the tracer
      side-manifest.
    </p>
    """
  end

  def render_closure_reach_status(_), do: ""

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

  defp render_requirements_coverage([], _, _, _), do: ""

  defp render_requirements_coverage(requirements, claims_by_req, closure_reach, req_status) do
    by_req = Map.get(closure_reach || %{}, :by_requirement, %{})
    status = Map.get(closure_reach || %{}, :status, :ok)

    render_one = fn req ->
      id = field(req, :id) || ""
      statement = field(req, :statement) || ""
      priority = field(req, :priority) || ""
      claims = Map.get(claims_by_req, id, [])
      best_strength = best_claim_strength(claims)
      meets_minimum? = Enum.all?(claims, &(&1["meets_minimum"] != false))
      reach = Map.get(by_req, id)
      change = Map.get(req_status, id, :unchanged)

      ~s"""
      <li class="cov-req cov-req-#{best_strength} cov-req-#{change}">
        <div class="cov-req-header">
          #{render_change_chip(change)}
          <code class="requirement-id">#{h(id)}</code>
          <span class="pill pill-priority pill-priority-#{h(priority)}"#{title_attr(tooltip(:priority, priority))}>#{h(priority)}</span>
          #{render_strength_badge(best_strength, claims, meets_minimum?)}
        </div>
        <p class="cov-req-statement" title="#{h(statement)}">#{h(statement)}</p>
        #{render_closure_reach(reach, status)}
        #{render_covering_claims(claims)}
      </li>
      """
    end

    {touched, untouched} =
      Enum.split_with(requirements, fn req ->
        id = field(req, :id) || ""
        Map.get(req_status, id, :unchanged) != :unchanged
      end)

    [
      ~s|<h4 class="tab-heading">Requirement coverage (#{length(requirements)})</h4>|,
      render_strength_legend(),
      render_coverage_touched_then_untouched(touched, untouched, render_one)
    ]
  end

  # Touched requirements render first in an open list; untouched requirements
  # fold behind a disclosure whose summary states their strength is unchanged
  # from base (per specled.spec_review.coverage_pivot_touched_first).
  defp render_coverage_touched_then_untouched([], [], _renderer), do: ""

  defp render_coverage_touched_then_untouched(touched, [], renderer) do
    [
      ~S|<ul class="cov-req-list">|,
      Enum.map(touched, renderer),
      ~S|</ul>|
    ]
  end

  defp render_coverage_touched_then_untouched([], untouched, renderer) do
    render_coverage_unchanged_disclosure(untouched, renderer)
  end

  defp render_coverage_touched_then_untouched(touched, untouched, renderer) do
    [
      ~S|<ul class="cov-req-list">|,
      Enum.map(touched, renderer),
      ~S|</ul>|,
      render_coverage_unchanged_disclosure(untouched, renderer)
    ]
  end

  defp render_coverage_unchanged_disclosure(untouched, renderer) do
    n = length(untouched)

    [
      ~s|<details class="unchanged-disclosure cov-unchanged-disclosure">|,
      ~s|<summary class="unchanged-summary">Show #{n} requirement#{maybe_s(n)} whose strength is unchanged from base</summary>|,
      ~s|<ul class="cov-req-list">|,
      Enum.map(untouched, renderer),
      ~S|</ul>|,
      ~S|</details>|
    ]
  end

  # covers: specled.spec_review.coverage_tab_bind_closure
  # Per-requirement bind-closure summary rendered beneath each requirement
  # in the Coverage tab. Format: "Closure: N MFAs. Reached: M (by tests
  # T1, T2). Unreached: K." When the artifact is missing the renderer
  # falls through to render_closure_reach_status/1 at the tab level and
  # this helper renders nothing per-row to avoid duplicate noise.
  defp render_closure_reach(_reach, :no_coverage_artifact), do: ""
  defp render_closure_reach(_reach, :no_tracer_manifest), do: ""
  defp render_closure_reach(nil, _), do: ""

  defp render_closure_reach(%{closure_mfa_count: 0, closure_file_count: 0}, _) do
    ~S|<p class="cov-closure" data-empty="true"><span class="cov-closure-label">Closure:</span> 0 MFAs.</p>|
  end

  defp render_closure_reach(reach, _) do
    %{
      closure_mfa_count: mfa_count,
      reached_files: reached,
      unreached_files: unreached,
      reaching_tests: tests
    } = reach

    reached_count = length(reached)
    unreached_count = length(unreached)

    tests_segment =
      case tests do
        [] -> ""
        list -> " (by tests #{render_reaching_tests(list)})"
      end

    ~s"""
    <p class="cov-closure">
      <span class="cov-closure-label">Closure:</span> #{mfa_count} MFA#{plural(mfa_count)}.
      <span class="cov-closure-reached">Reached: #{reached_count}#{tests_segment}.</span>
      <span class="cov-closure-unreached">Unreached: #{unreached_count}.</span>
    </p>
    """
  end

  defp render_reaching_tests(tests) do
    tests
    |> Enum.map(fn t -> ~s|<code class="cov-closure-test">#{h(t)}</code>| end)
    |> Enum.join(", ")
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

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

  # Per-subject raw-verification disclosure inside a subject pane: the author's
  # spec-verification declarations as written. Rendered only when the subject
  # actually declares verification entries.
  defp render_subject_raw_verification(subject) do
    case List.wrap(subject.verification) do
      [] ->
        ""

      list ->
        [
          ~s|<details class="raw-verification">|,
          ~s|<summary class="raw-verification-summary">Raw spec-verification (#{length(list)} entr#{if length(list) == 1, do: "y", else: "ies"})</summary>|,
          ~S|<p class="raw-verification-explainer">The author's declarations as written in this subject's spec file. The Coverage pivot above is computed from these entries.</p>|,
          render_raw_verification_subject(subject, list),
          ~S|</details>|
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

  # covers: specled.spec_review.decisions_governance_inline
  # The Decisions Changed panel is no longer purely descriptive. Append-only
  # governance findings (`append_only/*`) ride into the same section so that
  # an unauthorized requirement deletion or an ADR-bound violation surfaces
  # *next to* the ADR record where the reviewer is already focused. Findings
  # whose entity_id resolves to a present ADR render under that ADR's card;
  # the rest land in a "Governance violations" subsection at the top of the
  # panel so they are not silently dropped when no ADR file changed.
  @doc false
  def render_decisions_changed(decisions, adrs_by_id, findings \\ [])

  def render_decisions_changed([], adrs_by_id, findings) do
    governance = governance_findings(findings)
    {orphan_findings, _by_adr} = partition_governance_findings(governance, adrs_by_id || %{})

    case {governance, orphan_findings} do
      {[], _} ->
        ~S"""
        <section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">
          <h2 class="section-heading">Decisions changed (0)</h2>
          <p class="empty-tab">No ADR files changed in this change set.</p>
        </section>
        """

      _ ->
        [
          ~s|<section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">|,
          ~s|<h2 class="section-heading">Decisions changed (0)</h2>|,
          render_governance_orphans(orphan_findings),
          ~s|<p class="empty-tab">No ADR files changed in this change set.</p>|,
          ~S|</section>|
        ]
    end
  end

  def render_decisions_changed(decisions, adrs_by_id, findings) do
    governance = governance_findings(findings)
    adrs_by_id = adrs_by_id || %{}
    {orphan_findings, by_adr} = partition_governance_findings(governance, adrs_by_id)

    [
      ~s|<section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">|,
      ~s|<h2 class="section-heading">Decisions changed (#{length(decisions)})</h2>|,
      render_governance_orphans(orphan_findings),
      ~S|<div class="decision-changed-list">|,
      Enum.map(decisions, &render_changed_decision(&1, adrs_by_id, by_adr)),
      ~S|</div>|,
      ~S|</section>|
    ]
  end

  # An append_only/* finding tied to a known ADR id (e.g. adr_affects_widened
  # naming an ADR that's in adrs_by_id) renders under that ADR's card. All
  # other governance findings — unauthorized requirement deletions, decision
  # deletions of ADRs no longer present, etc. — surface at the top of the
  # panel as orphan governance violations.
  defp partition_governance_findings(findings, adrs_by_id) do
    Enum.reduce(findings, {[], %{}}, fn f, {orphans, by_adr} ->
      entity_id = f["entity_id"]

      cond do
        is_binary(entity_id) and Map.has_key?(adrs_by_id, entity_id) ->
          {orphans, Map.update(by_adr, entity_id, [f], &[f | &1])}

        true ->
          {[f | orphans], by_adr}
      end
    end)
    |> then(fn {orphans, by_adr} ->
      {Enum.reverse(orphans), Map.new(by_adr, fn {k, v} -> {k, Enum.reverse(v)} end)}
    end)
  end

  defp governance_findings(findings) do
    findings
    |> List.wrap()
    |> Enum.filter(fn f ->
      code = f["code"] || ""
      String.starts_with?(code, "append_only/")
    end)
  end

  defp render_governance_orphans([]), do: ""

  defp render_governance_orphans(findings) do
    [
      ~s|<details class="governance-orphans" open>|,
      ~s|<summary class="governance-orphans-summary">Governance violations (#{length(findings)})</summary>|,
      ~s|<p class="governance-orphans-explainer">These <code>append_only/*</code> findings are not authorized by any ADR in this change set. Each one is the spec system telling you a weakening landed without the decision trail it needs.</p>|,
      ~s|<ul class="governance-finding-list">|,
      Enum.map(findings, &render_governance_finding/1),
      ~s|</ul>|,
      ~s|</details>|
    ]
  end

  defp render_changed_decision(d, adrs_by_id, governance_by_adr) do
    findings = Map.get(governance_by_adr, d.id, [])

    body =
      case Map.get(adrs_by_id, d.id) do
        nil -> render_changed_decision_minimal(d)
        adr -> render_changed_decision_full(d, adr)
      end

    case findings do
      [] -> body
      _ -> [body, render_inline_governance_findings(findings)]
    end
  end

  defp render_changed_decision_minimal(d) do
    anchor = "adr-" <> slug(d.id || d.file)

    {chip, note} =
      if Map.get(d, :deleted?, false) do
        {~s|<span class="chip chip-removed">REMOVED</span>|,
         "decision file deleted in this change set (base version could not be parsed)"}
      else
        {"", "decision changed but no parsed ADR available"}
      end

    ~s"""
    <details class="adr" id="#{anchor}">
      <summary class="adr-summary">
        #{chip}
        <code class="adr-id">#{h(d.id || d.file)}</code>
        <span class="adr-title-missing">#{note}</span>
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

    removed_note =
      if Map.get(adr, :change_status) == :removed do
        ~S|<p class="adr-removed-note">This decision file was deleted in this change set. The content below is the last version at the base ref.</p>|
      else
        ""
      end

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
        #{removed_note}
        <div class="markdown-body">#{render_markdown(adr.body_text)}</div>
        #{if adr.file, do: ~s|<div class="adr-source"><code>#{h(adr.file)}</code></div>|, else: ""}
      </div>
    </details>
    """
  end

  defp render_inline_governance_findings(findings) do
    [
      ~s|<div class="governance-finding-inline">|,
      ~s|<p class="governance-finding-inline-label">Governance findings naming this ADR:</p>|,
      ~s|<ul class="governance-finding-list">|,
      Enum.map(findings, &render_governance_finding/1),
      ~s|</ul>|,
      ~s|</div>|
    ]
  end

  defp render_governance_finding(f) do
    sev = f["severity"] || "error"
    code = f["code"] || ""
    message = f["message"] || ""
    {prose, fix_block} = split_fix_block(message)

    fix_html =
      case fix_block do
        nil -> ""
        text -> ~s|<pre class="governance-finding-fix"><code>#{h(text)}</code></pre>|
      end

    ~s"""
    <li class="governance-finding finding-#{h(sev)}">
      <div class="governance-finding-header">
        <span class="finding-severity"#{title_attr(tooltip(:severity, sev))}>#{h(sev)}</span>
        <span class="finding-code">#{h(code)}</span>
        #{render_subject_link(f["subject_id"])}
      </div>
      <p class="governance-finding-message">#{h(prose)}</p>
      #{fix_html}
    </li>
    """
  end

  # AppendOnly messages are produced by `finalize_message/2` as
  # "<prose>\n\n```\nfix: ...\n```\n". We split them so the prose flows as
  # readable text and the fix line keeps its monospace, code-fenced shape.
  defp split_fix_block(message) when is_binary(message) do
    case Regex.run(~r/^(.*?)\n*```\n(fix:[^\n]*(?:\n[^\n]*)*)\n```\s*$/s, message) do
      [_, prose, fix_text] -> {String.trim_trailing(prose), String.trim(fix_text)}
      _ -> {message, nil}
    end
  end

  defp split_fix_block(other), do: {to_string(other), nil}

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
        render_file_diff_details(file, lines, "misc-" <> slug(file))
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
        #{misc_breakdown_row(mapped, "map to a spec subject", "see each subject's Code tab, reachable from the queue", nil)}
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
    ~s|<span class="diffstat" title="#{files} file#{if files == 1, do: "", else: "s"} changed · +#{adds} −#{dels} lines"><span class="diffstat-files">#{files} file#{if files == 1, do: "", else: "s"}</span><span class="diffstat-add">+#{adds}</span><span class="diffstat-del">−#{dels}</span><span class="diffstat-bar" aria-hidden="true">#{render_diffstat_bar(adds, dels)}</span></span>#{render_diffstat_info()}|
  end

  def render_diff_stats(_), do: ""

  # These counts intentionally diverge from what GitHub shows for the same
  # change set: tool-managed spec state files are regenerable derived state
  # and are excluded from review (ChangeAnalysis.tool_managed_spec_file?/1).
  # The info popover keeps that divergence from reading as a bug.
  defp render_diffstat_info do
    ~s|<span class="diffstat-info" tabindex="0" role="note" aria-label="Why these counts differ from GitHub">ⓘ<span class="diffstat-info-tip">These counts can differ from GitHub&#39;s. Tool-managed spec state files (<code>.spec/state.json</code>, <code>.spec/realization_hashes.json</code>) are regenerated by <code>mix spec.check</code> and excluded from this review&#39;s diff.</span></span>|
  end

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
        render_file_diff_details(file, lines, "files-" <> slug(file))
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
    do:
      "Runs an arbitrary command. Reaches EXECUTED when the command exits 0 with --run-commands."

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

  defp tooltip(:change, :new_subject),
    do: "This subject's spec file did not exist on the base ref"

  defp tooltip(:change, :spec_edited),
    do: "The subject's .spec.md file was edited in this change set"

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
      --modified: #7c3aed;
      --modified-bg: #f5f3ff;
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

    /* Dark token set. Applied when the OS prefers dark and the viewer has not
       forced light, OR when the viewer explicitly forces dark via the toggle.
       Forcing light re-selects the :root light set because the media query is
       excluded by :not([data-theme="light"]). */
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #0d1117;
        --fg: #e6edf3;
        --fg-muted: #9198a1;
        --fg-faint: #6e7681;
        --card-bg: #161b22;
        --border: #30363d;
        --border-strong: #444c56;
        --accent: #4493f8;
        --error: #ff7b72;
        --error-bg: #2d1416;
        --warning: #e3b341;
        --warning-bg: #272013;
        --info: #79c0ff;
        --info-bg: #0f2338;
        --success: #3fb950;
        --success-bg: #12261a;
        --modified: #a78bfa;
        --modified-bg: #211a35;
        --neutral-bg: #21262d;
        --add-bg: #12261a;
        --add-fg: #3fb950;
        --del-bg: #2d1416;
        --del-fg: #ff7b72;
        --hunk-bg: #0c2d5a;
        --hunk-fg: #79c0ff;
      }
    }

    :root[data-theme="dark"] {
      --bg: #0d1117;
      --fg: #e6edf3;
      --fg-muted: #9198a1;
      --fg-faint: #6e7681;
      --card-bg: #161b22;
      --border: #30363d;
      --border-strong: #444c56;
      --accent: #4493f8;
      --error: #ff7b72;
      --error-bg: #2d1416;
      --warning: #e3b341;
      --warning-bg: #272013;
      --info: #79c0ff;
      --info-bg: #0f2338;
      --success: #3fb950;
      --success-bg: #12261a;
      --modified: #a78bfa;
      --modified-bg: #211a35;
      --neutral-bg: #21262d;
      --add-bg: #12261a;
      --add-fg: #3fb950;
      --del-bg: #2d1416;
      --del-fg: #ff7b72;
      --hunk-bg: #0c2d5a;
      --hunk-fg: #79c0ff;
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
    .diffstat-info {
      position: relative;
      margin-left: 6px;
      color: var(--fg-muted);
      font-size: 12px;
      cursor: help;
    }
    .diffstat-info-tip {
      display: none;
      position: absolute;
      top: calc(100% + 6px);
      left: 50%;
      transform: translateX(-50%);
      width: 320px;
      padding: 10px 12px;
      background: var(--card-bg);
      border: 1px solid var(--border-strong);
      border-radius: 6px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
      color: var(--fg);
      font-family: var(--body-font, inherit);
      font-size: 12px;
      font-weight: 400;
      line-height: 1.5;
      white-space: normal;
      z-index: 30;
    }
    .diffstat-info:hover .diffstat-info-tip,
    .diffstat-info:focus .diffstat-info-tip { display: block; }

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
    /* Advisory-only (no blocking findings): neutral, not alarming — same
       "degraded ≠ warning" tone as the triangle's degraded-leg styling. */
    .sync-headline-icon-advisory { background: var(--neutral-bg); color: var(--fg-muted); }

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
    /* Degraded edge: detector_unavailable on this leg. Neutral grey with a
       ? glyph — not amber. "Couldn't check" must not read as "something is
       wrong"; the system is being honest that the detector could not run. */
    .sync-edge-degraded .sync-edge-line { background: var(--fg-faint); }
    .sync-edge-degraded .sync-edge-line::after { border-left-color: var(--fg-faint); }
    .sync-edge-degraded .sync-edge-icon { color: var(--fg-muted); }
    .sync-edge-degraded .sync-edge-label { color: var(--fg-muted); }
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
    .sync-check-fail { background: var(--error-bg); border-left: 3px solid var(--error); padding-left: 6px; }
    /* Degraded is neutral, not a warning (per the banner above) — grey, not
       amber, so it doesn't read as a failure alongside actual .sync-check-fail
       rows. Border/icon reuse --border-strong (not --fg-muted, a text-only
       token) since this is a border, not text. */
    .sync-check-degraded { background: var(--neutral-bg); border-left: 3px solid var(--border-strong); padding-left: 6px; }
    .sync-check-vacuous { background: transparent; opacity: 0.7; }
    .sync-check-icon { font-weight: 700; font-size: 14px; text-align: center; }
    .sync-check-ok .sync-check-icon { color: var(--success); }
    .sync-check-fail .sync-check-icon { color: var(--error); }
    .sync-check-degraded .sync-check-icon { color: var(--fg-muted); }
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
    /* Neutral, matching .sync-check-vacuous-tag — same "degraded ≠ warning"
       reasoning as .sync-check-degraded above. */
    .sync-check-degraded-tag {
      font-size: 11px;
      font-weight: 600;
      color: var(--fg-muted);
      background: var(--neutral-bg);
      padding: 2px 8px;
      border-radius: 999px;
      white-space: nowrap;
    }
    /* Degraded is neutral, not a warning: grey surface, ? glyph. */
    .sync-degraded-banner {
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 12px;
      margin-bottom: 10px;
      background: var(--neutral-bg);
      border: 1px solid var(--border);
      border-left: 4px solid var(--fg-faint);
      border-radius: 4px;
      color: var(--fg-muted);
      font-size: 13px;
      line-height: 1.45;
    }
    .sync-degraded-icon {
      font-weight: 700;
      font-size: 16px;
      color: var(--fg-muted);
      flex-shrink: 0;
    }
    .sync-degraded-text code {
      font-family: var(--code-font);
      font-size: 11px;
      background: var(--card-bg);
      color: var(--fg-muted);
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

    /* Per-row tinting for new/modified. Background/border use theme tokens
       (not hardcoded hex) because the row's own text inherits --fg, which
       switches to near-white in dark mode — a hardcoded light background
       left the text unreadable there. */
    .requirement-new,
    .scenario-new {
      background: var(--success-bg);
      border-left: 3px solid var(--success);
      padding-left: 12px;
      margin-left: -12px;
      border-radius: 0 4px 4px 0;
    }
    .requirement-modified,
    .scenario-modified {
      background: var(--modified-bg);
      border-left: 3px solid var(--modified);
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
      background: var(--error-bg);
      border-left: 3px solid var(--error);
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
    .badge-binding-empty { background: var(--neutral-bg); color: var(--fg-muted); }
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
    .findings-group { margin-top: 12px; }
    .findings-group:first-of-type { margin-top: 4px; }
    .findings-group-heading {
      display: flex;
      flex-wrap: wrap;
      align-items: baseline;
      gap: 8px;
      margin: 0;
      padding: 8px 0 4px;
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--fg-muted);
      border-bottom: 1px solid var(--border);
    }
    .findings-group-leg { color: var(--fg); }
    .findings-group-count { color: var(--fg-faint); font-weight: 500; text-transform: none; letter-spacing: 0; }
    .findings-group-sev {
      display: inline-block;
      padding: 1px 6px;
      border-radius: 3px;
      font-size: 10px;
      font-weight: 600;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    .findings-group-sev-error { background: var(--error-bg); color: var(--error); }
    .findings-group-sev-warning { background: var(--warning-bg); color: var(--warning); }
    .findings-group-sev-info { background: var(--info-bg); color: var(--info); }
    .findings-group-list { list-style: none; margin: 0; padding: 0; }
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
    .finding-subject-pair { font-size: 12px; color: var(--fg-muted); display: inline; }
    .finding-subject-label { font-family: var(--body-font); color: var(--fg-muted); }
    .finding-message { color: var(--fg); }

    /* Subject card.
       No `overflow: hidden` here: it clips rounded corners, but it also
       makes this the nearest ancestor with a non-visible overflow for every
       `position: sticky` descendant (the pivot tab bar, sticky filename
       headers, the file-tree drawer) — since this box itself never scrolls,
       that silently breaks their stickiness relative to the page instead of
       clipping anything visible (subject-header and tab-panels are both
       transparent and inset by padding, so nothing was actually being
       clipped). Corner-rounding is preserved explicitly on the first/last
       child instead. */
    .subject {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      margin-bottom: 16px;
      scroll-margin-top: 16px;
    }
    .subject-header {
      padding: 24px 24px 16px;
      border-bottom: 1px solid var(--border);
      border-radius: 8px 8px 0 0;
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

    /* Clamped prose headline with a pure-CSS expand toggle. */
    .subject-statement-wrap { margin: 0 0 12px 0; }
    .statement-toggle { position: absolute; opacity: 0; pointer-events: none; }
    .subject-statement-clamped {
      display: -webkit-box;
      -webkit-line-clamp: 3;
      -webkit-box-orient: vertical;
      overflow: hidden;
    }
    .statement-toggle:checked ~ .subject-statement-clamped {
      -webkit-line-clamp: unset;
      overflow: visible;
    }
    .statement-expand {
      display: inline-block;
      margin-top: 4px;
      font-size: 12px;
      font-weight: 500;
      color: var(--accent);
      cursor: pointer;
    }
    .statement-expand::after { content: "Show more"; }
    .statement-toggle:checked ~ .statement-expand::after { content: "Show less"; }

    /* Per-subject triangle leg chips. */
    .subject-legs {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .leg-chip {
      display: inline-flex;
      align-items: center;
      gap: 5px;
      font-size: 11px;
      font-weight: 500;
      padding: 2px 8px;
      border-radius: 10px;
      border: 1px solid var(--border);
      color: var(--fg-muted);
      background: var(--neutral-bg);
    }
    .leg-chip-glyph { font-weight: 700; }
    .leg-chip-ok { color: var(--success); background: var(--success-bg); border-color: var(--success); }
    .leg-chip-degraded { color: var(--fg-muted); background: var(--neutral-bg); }
    .leg-chip-warn { color: var(--warning); background: var(--warning-bg); border-color: var(--warning); }
    .leg-chip-fail { color: var(--error); background: var(--error-bg); border-color: var(--error); }

    /* Tabs.
       Sticky so the pivot bar (and which pivot is active) stays reachable
       while scrolling a long panel — most load-bearing for the Code pivot,
       which can run to thousands of diff lines. `top` matches .topbar's
       height so it docks directly under it. */
    .tabs {
      display: flex;
      gap: 0;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
      padding: 0 12px;
      position: sticky;
      top: 57px;
      z-index: 12;
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
    .tab-panels { padding: 24px; border-radius: 0 0 8px 8px; }
    .tab-panel { display: none; }
    .tab-panel.active { display: block; }

    /* An empty pivot is de-emphasized; its tooltip carries the reason. */
    .tab.tab-empty { color: var(--fg-faint); opacity: 0.6; cursor: help; }
    .tab.tab-empty.active { color: var(--fg-muted); opacity: 1; }

    /* Code pivot grouped by realized_by binding tier. */
    .code-tier { margin-bottom: 24px; }
    .code-tier-heading {
      display: flex;
      align-items: baseline;
      gap: 8px;
      margin: 0 0 12px 0;
      font-size: 13px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--fg-muted);
    }
    .code-tier-count { font-weight: 500; color: var(--fg-faint); }
    .code-tier-note {
      margin: 0 0 12px 0;
      font-size: 12px;
      color: var(--fg-faint);
      font-style: italic;
    }

    /* Raw spec file diff, folded under the semantic spec diff. */
    .spec-diff-fold { margin-top: 32px; }
    .spec-diff-summary {
      cursor: pointer;
      font-size: 13px;
      font-weight: 600;
      color: var(--fg-muted);
    }

    /* Inline wording del/ins on modified requirement statements. */
    .wording-del {
      background: var(--error-bg);
      color: var(--error);
      text-decoration: line-through;
    }
    .wording-ins {
      background: var(--success-bg);
      color: var(--success);
      text-decoration: none;
    }
    /* Heavily rewritten statements stack old over new instead of interleaving. */
    .wording-rewrite { display: block; }
    .wording-block {
      display: block;
      padding: 2px 6px;
      border-radius: 3px;
    }
    .wording-block + .wording-block { margin-top: 4px; }

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
    .cov-req-uncovered { border-left-color: var(--error); background: var(--error-bg); }
    .cov-req-header {
      display: flex;
      align-items: center;
      gap: 8px;
      flex-wrap: wrap;
      margin-bottom: 4px;
    }
    /* The full statement already reads in full on the Spec pivot — the
       Coverage pivot's job is id + strength + evidence, so one line here
       (hover for the rest) halves the list's height with no information
       lost. */
    .cov-req-statement {
      margin: 0 0 8px 0;
      color: var(--fg);
      font-size: 13px;
      line-height: 1.5;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      cursor: help;
    }

    /* Coverage tab — per-requirement bind-closure summary */
    .cov-closure {
      margin: 4px 0 8px 0;
      font-size: 12px;
      color: var(--fg-muted);
      line-height: 1.55;
    }
    .cov-closure-label { font-weight: 600; color: var(--fg); }
    .cov-closure-reached { margin-left: 8px; }
    .cov-closure-unreached { margin-left: 8px; }
    .cov-closure-test {
      font-family: var(--code-font);
      font-size: 11px;
      background: var(--neutral-bg);
      padding: 1px 4px;
      border-radius: 3px;
    }
    .cov-closure-unavailable {
      margin: 8px 0 12px 0;
      padding: 8px 10px;
      border: 1px dashed var(--border);
      border-radius: 4px;
      background: var(--neutral-bg);
      color: var(--fg-muted);
      font-size: 12px;
      line-height: 1.5;
    }
    .cov-closure-unavailable strong { color: var(--fg); }
    .cov-closure-unavailable code {
      font-family: var(--code-font);
      font-size: 11px;
      background: var(--bg);
      padding: 1px 4px;
      border-radius: 3px;
    }

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
    .adr-removed-note {
      margin: 10px 0 0;
      padding: 8px 12px;
      background: var(--error-bg);
      color: var(--error);
      border-radius: 4px;
      font-size: 12px;
    }

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

    .governance-orphans {
      border: 1px solid var(--error);
      border-radius: 6px;
      padding: 12px 16px;
      margin: 0 0 16px;
      background: var(--error-bg, var(--neutral-bg));
    }
    .governance-orphans-summary {
      cursor: pointer;
      font-weight: 600;
      color: var(--error);
      font-size: 13px;
    }
    .governance-orphans-explainer {
      margin: 8px 0 8px;
      color: var(--fg-muted);
      font-size: 12px;
    }
    .governance-finding-list {
      list-style: none;
      margin: 0;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 10px;
    }
    .governance-finding {
      display: flex;
      flex-direction: column;
      gap: 6px;
      padding: 10px 12px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--card-bg);
    }
    .governance-finding.finding-error { border-color: var(--error); }
    .governance-finding.finding-warning { border-color: var(--warning); }
    .governance-finding.finding-info { border-color: var(--info); }
    .governance-finding-header {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: baseline;
    }
    .governance-finding-message {
      margin: 0;
      color: var(--fg);
      font-size: 13px;
      line-height: 1.5;
    }
    .governance-finding-fix {
      margin: 0;
      padding: 8px 12px;
      background: var(--neutral-bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      font-family: var(--code-font);
      font-size: 12px;
      white-space: pre-wrap;
      word-break: break-word;
      color: var(--fg);
    }
    .governance-finding-inline {
      margin: 8px 0 4px;
      padding: 12px;
      border-left: 3px solid var(--error);
      background: var(--neutral-bg);
      border-radius: 0 6px 6px 0;
    }
    .governance-finding-inline-label {
      margin: 0 0 8px;
      font-size: 12px;
      font-weight: 600;
      color: var(--error);
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }

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
    .code-change-note {
      color: var(--fg-muted);
      font-size: 11px;
      font-style: italic;
      margin-left: auto;
      white-space: nowrap;
    }
    /* Sticky filename header (GitHub-style): the currently-open file's name
       stays visible while scrolling through its diff. Default offset docks
       under .topbar alone (used by the standalone Outside-the-spec-system
       and All-files panes); inside a subject's tab-panels the sticky tab
       bar also occupies that band, so the offset is pushed down to clear it. */
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
      position: sticky;
      top: 57px;
      z-index: 8;
    }
    .tab-panels .filename { top: 98px; }
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
         section) always has enough height to remain sticky-relevant even
         when every file diff is collapsed and the section's natural
         content height shrinks to almost nothing. */
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

    /* Default offset docks the drawer below the sticky topbar alone (used
       by the standalone Outside-the-spec-system and All-files panes).
       Inside a subject's tab-panels the sticky pivot tab bar also occupies
       that band, so the offset is pushed down to clear it — same split as
       .filename's above. */
    .file-tree-panel,
    .file-tree-handle {
      pointer-events: auto;
      position: sticky;
      top: 73px;
    }
    .tab-panels .file-tree-panel,
    .tab-panels .file-tree-handle {
      top: 98px;
    }

    .file-tree-panel {
      width: 240px;
      max-height: calc(100vh - 89px);
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
    .tab-panels .file-tree-panel { max-height: calc(100vh - 114px); }
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

    /* Prism's bundled theme paints .token.operator/.entity/.url (and CSS
       string tokens) with a translucent WHITE background — invisible on
       Prism's near-white default, but a visible gray box on our dark
       background. Neutralize it under both dark paths (system default and
       explicit toggle) so operators read as plain colored text. */
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) .token.operator,
      :root:not([data-theme="light"]) .token.entity,
      :root:not([data-theme="light"]) .token.url,
      :root:not([data-theme="light"]) .language-css .token.string,
      :root:not([data-theme="light"]) .style .token.string {
        background: transparent;
      }
    }
    :root[data-theme="dark"] .token.operator,
    :root[data-theme="dark"] .token.entity,
    :root[data-theme="dark"] .token.url,
    :root[data-theme="dark"] .language-css .token.string,
    :root[data-theme="dark"] .style .token.string {
      background: transparent;
    }

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

    /* ── Master–detail shell ─────────────────────────────────────────── */
    .topbar {
      position: sticky;
      top: 0;
      z-index: 20;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 12px 24px;
      background: var(--card-bg);
      border-bottom: 1px solid var(--border);
    }
    .topbar-left { display: flex; align-items: baseline; gap: 16px; flex-wrap: wrap; }
    .topbar-left h1 { margin: 0; font-size: 18px; font-weight: 600; letter-spacing: -0.01em; }
    .topbar-right { display: flex; align-items: center; gap: 12px; }

    .verdict-chip {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 5px 12px;
      border-radius: 999px;
      font-size: 13px;
      font-weight: 600;
      border: 1px solid var(--border);
      white-space: nowrap;
    }
    .verdict-chip-clean { color: var(--success); background: var(--success-bg); border-color: var(--success); }
    .verdict-chip-error { color: var(--error); background: var(--error-bg); border-color: var(--error); }
    .verdict-chip-warning { color: var(--warning); background: var(--warning-bg); border-color: var(--warning); }
    .verdict-chip-info { color: var(--info); background: var(--info-bg); border-color: var(--info); }
    .verdict-chip-nondiff { color: var(--fg-muted); background: var(--neutral-bg); }

    .theme-toggle {
      display: inline-flex;
      gap: 2px;
      padding: 2px;
      background: var(--neutral-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
    }
    .theme-btn {
      background: transparent;
      border: none;
      cursor: pointer;
      padding: 4px 8px;
      border-radius: 6px;
      font-size: 14px;
      line-height: 1;
      color: var(--fg-muted);
    }
    .theme-btn:hover { color: var(--fg); }
    .theme-btn.active { background: var(--card-bg); color: var(--fg); box-shadow: 0 1px 2px rgba(0,0,0,0.12); }

    .layout {
      display: grid;
      grid-template-columns: 300px minmax(0, 1fr);
      gap: 0;
      max-width: 1400px;
      margin: 0 auto;
      align-items: start;
    }
    .queue {
      position: sticky;
      top: 57px;
      align-self: start;
      max-height: calc(100vh - 57px);
      overflow-y: auto;
      padding: 16px 12px;
      border-right: 1px solid var(--border);
    }
    .queue-filter {
      width: 100%;
      padding: 6px 10px;
      margin-bottom: 12px;
      font: inherit;
      font-size: 13px;
      color: var(--fg);
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
    }
    .queue-list { list-style: none; margin: 0; padding: 0; }
    .queue-group-label {
      margin: 12px 6px 4px;
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 0.04em;
      color: var(--fg-faint);
    }
    .queue-item { margin: 1px 0; }
    .queue-link {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 6px 8px;
      border-radius: 6px;
      color: var(--fg);
      text-decoration: none;
      font-size: 13px;
    }
    .queue-link:hover { background: var(--neutral-bg); }
    .queue-current > .queue-link { background: var(--info-bg); color: var(--info); font-weight: 600; }
    .queue-count {
      display: inline-block;
      min-width: 18px;
      padding: 0 5px;
      text-align: center;
      font-size: 11px;
      color: var(--fg-muted);
      background: var(--neutral-bg);
      border-radius: 999px;
    }
    .queue-subject-id { font-family: var(--code-font); font-size: 12px; flex: 1; overflow: hidden; text-overflow: ellipsis; }
    .queue-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
    .queue-dot-none { background: transparent; box-shadow: inset 0 0 0 1px var(--border-strong); }
    .queue-dot-error { background: var(--error); }
    .queue-dot-warning { background: var(--warning); }
    .queue-dot-info { background: var(--info); }
    .queue-chip {
      font-size: 9px;
      font-weight: 700;
      letter-spacing: 0.03em;
      padding: 1px 4px;
      border-radius: 3px;
    }
    .queue-chip-spec { color: var(--accent); background: var(--info-bg); }
    .queue-filecount { font-size: 11px; color: var(--fg-faint); flex-shrink: 0; }
    .queue-badge {
      font-size: 10px;
      font-weight: 700;
      padding: 1px 5px;
      border-radius: 3px;
    }
    .queue-badge-degraded { color: var(--fg-muted); background: var(--neutral-bg); border: 1px solid var(--border); }

    .detail { min-width: 0; padding: 24px 32px; }
    .detail-pane { display: none; }
    .detail-pane.active { display: block; }
    .detail-pane:focus { outline: none; }

    /* ── Overview (change-scoped) ────────────────────────────────────── */
    .overview-headline h2 { margin: 0 0 4px; font-size: 20px; letter-spacing: -0.01em; }
    .overview-headline p { margin: 0 0 16px; color: var(--fg-muted); font-size: 14px; }
    .overview-headline-clean h2 { color: var(--success); }
    .overview-headline-nondiff h2 { color: var(--fg-muted); }
    .overview-sev-row { display: flex; gap: 8px; }
    .overview-sev { font-size: 12px; font-weight: 600; padding: 2px 8px; border-radius: 999px; }
    .overview-sev-error { color: var(--error); background: var(--error-bg); }
    .overview-sev-warning { color: var(--warning); background: var(--warning-bg); }
    .overview-sev-info { color: var(--info); background: var(--info-bg); }
    .overview-tiles {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 12px;
      margin: 8px 0 24px;
    }
    .overview-tile {
      display: flex;
      flex-direction: column;
      gap: 2px;
      padding: 14px 16px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
    }
    .overview-tile-num { font-size: 26px; font-weight: 700; letter-spacing: -0.02em; }
    .overview-tile-label { font-size: 12px; color: var(--fg-muted); }
    .overview-section-heading { margin: 24px 0 10px; font-size: 15px; font-weight: 600; }
    .overview-nondiff-note, .overview-delta-count, .overview-spec-edit-counts { font-weight: 400; font-size: 12px; color: var(--fg-muted); }
    .overview-delta-group { margin-bottom: 14px; }
    .overview-delta-heading { margin: 0 0 6px; font-size: 13px; font-weight: 600; }
    .overview-delta-pre-existing .overview-delta-heading { color: var(--fg-muted); }
    .overview-spec-edits-list, .overview-decisions-list { list-style: none; margin: 0; padding: 0; }
    .overview-spec-edits-list li, .overview-decisions-list li { padding: 4px 0; font-size: 13px; }
    .overview-decisions-more { margin: 8px 0 0; font-size: 13px; }
    .overview-decisions-more a, .overview-spec-edits-list a { color: var(--accent); text-decoration: none; }
    .overview-meter {
      display: flex;
      height: 12px;
      border-radius: 6px;
      overflow: hidden;
      background: var(--neutral-bg);
    }
    .overview-meter-seg { min-width: 2px; }
    .overview-meter-mapped { background: var(--success); }
    .overview-meter-policy { background: var(--accent); }
    .overview-meter-unmapped { background: var(--fg-faint); }
    .overview-meter-legend {
      display: flex;
      gap: 16px;
      list-style: none;
      margin: 8px 0 0;
      padding: 0;
      font-size: 12px;
      color: var(--fg-muted);
    }
    .overview-meter-legend li { display: flex; align-items: center; gap: 5px; }
    .overview-meter-key { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }

    /* ── Spec health (repo state) ────────────────────────────────────── */
    .spec-health-head h2 { margin: 0 0 4px; font-size: 20px; letter-spacing: -0.01em; }
    .spec-health-scope { font-size: 14px; font-weight: 400; color: var(--fg-muted); }
    .spec-health-note { margin: 0 0 8px; font-size: 13px; color: var(--fg-muted); }
    .spec-health-partial { margin: 0 0 12px; font-size: 13px; color: var(--fg-muted); font-weight: 600; }
    .strength-inventory, .repo-inventory, .health-findings { margin-top: 24px; }
    .strength-inventory-list, .repo-inventory-list {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      list-style: none;
      margin: 8px 0 0;
      padding: 0;
    }
    .strength-inventory-list li, .repo-inventory-list li {
      display: flex;
      align-items: center;
      gap: 6px;
      padding: 6px 12px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 6px;
      font-size: 13px;
    }
    .strength-inventory-count, .repo-inventory-count { font-weight: 700; }
    .repo-inventory-label { color: var(--fg-muted); }

    /* ── Findings digest (dedup by code, reason) ─────────────────────── */
    .findings-digest { list-style: none; margin: 8px 0 0; padding: 0; }
    .findings-digest-row {
      padding: 8px 12px;
      margin-bottom: 6px;
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-left-width: 3px;
      border-radius: 6px;
    }
    .findings-digest-error { border-left-color: var(--error); }
    .findings-digest-warning { border-left-color: var(--warning); }
    .findings-digest-info { border-left-color: var(--info); }
    .findings-digest-main { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
    .findings-digest-sev {
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
      padding: 1px 6px;
      border-radius: 3px;
    }
    .findings-group-sev-error { color: var(--error); background: var(--error-bg); }
    .findings-group-sev-warning { color: var(--warning); background: var(--warning-bg); }
    .findings-group-sev-info { color: var(--info); background: var(--info-bg); }
    .findings-digest-code { font-family: var(--code-font); font-size: 12px; }
    .findings-digest-reason { font-size: 12px; color: var(--fg-muted); }
    .findings-digest-count { margin-left: auto; font-weight: 700; font-size: 13px; }
    .findings-digest-subjects { margin-top: 6px; font-size: 12px; }
    .findings-digest-subjects summary { cursor: pointer; color: var(--fg-muted); }
    .findings-digest-subjects ul { list-style: none; margin: 6px 0 0; padding: 0 0 0 14px; }
    .findings-digest-subjects li { padding: 2px 0; }
    .findings-digest-subjects a { color: var(--accent); text-decoration: none; }

    @media (max-width: 860px) {
      .layout { grid-template-columns: 1fr; }
      .queue { position: static; max-height: none; border-right: none; border-bottom: 1px solid var(--border); }
    }
    @media (max-width: 720px) {
      .page-header, .layout, .page-footer { padding-left: 16px; padding-right: 16px; }
      .finding-item { grid-template-columns: 1fr; gap: 4px; }
    }
    """
  end

  # covers: specled.spec_review.theme_tokens
  # Applied synchronously in <head> before first paint: read the persisted
  # theme choice from localStorage and stamp `data-theme` on the root element
  # so the correct token set is active on the very first frame (no flash). A
  # "system" choice (or no stored choice) leaves the attribute off so the
  # prefers-color-scheme media query decides.
  @doc false
  def theme_bootstrap_js do
    """
    (function () {
      try {
        var choice = localStorage.getItem('specled-theme');
        if (choice === 'light' || choice === 'dark') {
          document.documentElement.setAttribute('data-theme', choice);
        }
      } catch (e) {}
    })();
    """
  end

  defp js do
    """
    // Theme toggle: system / light / dark, persisted to localStorage.
    function applyTheme(choice) {
      if (choice === 'light' || choice === 'dark') {
        document.documentElement.setAttribute('data-theme', choice);
      } else {
        document.documentElement.removeAttribute('data-theme');
      }
      document.querySelectorAll('.theme-btn').forEach(function (b) {
        b.classList.toggle('active', b.getAttribute('data-theme-choice') === choice);
      });
    }

    (function () {
      var stored = 'system';
      try { stored = localStorage.getItem('specled-theme') || 'system'; } catch (e) {}
      applyTheme(stored);
    })();

    document.addEventListener('click', function (e) {
      var btn = e.target.closest('.theme-btn');
      if (!btn) return;
      var choice = btn.getAttribute('data-theme-choice');
      try { localStorage.setItem('specled-theme', choice); } catch (e) {}
      applyTheme(choice);
    });

    // Master–detail queue navigation. Exactly one detail pane is visible at a
    // time; the visible pane is driven by the URL fragment so every unit is
    // deep-linkable. A fragment may name a pane directly (unit-…) or any
    // element inside a pane (e.g. an inline finding anchor), in which case the
    // owning pane is activated and the element scrolled into view.
    function paneForHash(hash) {
      if (!hash || hash === '#') return null;
      var id = hash.slice(1);
      var el = document.getElementById(id);
      if (!el) return null;
      if (el.classList.contains('detail-pane')) return el;
      return el.closest('.detail-pane');
    }

    function selectPane(pane, focusEl) {
      if (!pane) return;
      document.querySelectorAll('.detail-pane').forEach(function (p) {
        p.classList.toggle('active', p === pane);
      });
      var unit = pane.getAttribute('data-unit');
      document.querySelectorAll('.queue-item').forEach(function (item) {
        var current = item.getAttribute('data-unit') === unit;
        item.classList.toggle('queue-current', current);
        var link = item.querySelector('.queue-link');
        if (link) {
          if (current) { link.setAttribute('aria-current', 'true'); }
          else { link.removeAttribute('aria-current'); }
        }
      });
      if (focusEl && focusEl !== pane) {
        focusEl.scrollIntoView({ block: 'start' });
      } else {
        pane.scrollTop = 0;
      }
    }

    function syncFromHash() {
      var pane = paneForHash(location.hash);
      if (pane) {
        var target = document.getElementById(location.hash.slice(1));
        selectPane(pane, target);
      } else {
        var overview = document.querySelector('.detail-pane[data-unit="overview"]');
        selectPane(overview, null);
      }
    }

    window.addEventListener('hashchange', syncFromHash);
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', syncFromHash);
    } else {
      syncFromHash();
    }

    // Filter the subject rows in the queue by subject id.
    document.addEventListener('input', function (e) {
      var input = e.target.closest('.queue-filter');
      if (!input) return;
      var q = input.value.trim().toLowerCase();
      document.querySelectorAll('.queue-subject').forEach(function (item) {
        var id = (item.getAttribute('data-subject-id') || '').toLowerCase();
        item.style.display = (q === '' || id.indexOf(q) !== -1) ? '' : 'none';
      });
    });

    // j / k move the selection through the visible queue items.
    document.addEventListener('keydown', function (e) {
      if (e.key !== 'j' && e.key !== 'k') return;
      var tag = (e.target.tagName || '').toLowerCase();
      if (tag === 'input' || tag === 'textarea' || e.target.isContentEditable) return;
      var items = Array.prototype.filter.call(
        document.querySelectorAll('.queue-item'),
        function (it) { return it.style.display !== 'none'; }
      );
      if (!items.length) return;
      var idx = items.findIndex(function (it) { return it.classList.contains('queue-current'); });
      if (e.key === 'j') { idx = (idx < 0) ? 0 : Math.min(idx + 1, items.length - 1); }
      else { idx = (idx < 0) ? 0 : Math.max(idx - 1, 0); }
      var link = items[idx].querySelector('.queue-link');
      if (link) { location.hash = link.getAttribute('href'); }
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
