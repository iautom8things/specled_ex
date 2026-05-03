defmodule SpecLedEx.Review.Html do
  @moduledoc """
  Renders a `SpecLedEx.Review.build_view/3` view-model as a self-contained
  HTML string. CSS and JS are embedded inline so the artifact has no
  network dependency at view time.

  This module does no data fetching of its own — feed it the assembled
  view-model and it returns iodata.
  """

  require EEx

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
    <style><%= css %></style>
  </head>
  <body>
    <header class="page-header">
      <div class="page-header-row">
        <h1>Spec Review</h1>
        <div class="page-header-meta">
          <span class="ref"><%= h(view.meta.base_ref) %><span class="ref-sep">…</span><%= h(view.meta.head_ref) %></span>
          <span class="generated"><%= h(format_dt(view.meta.generated_at)) %></span>
        </div>
      </div>
    </header>
    <div class="layout">
      <aside class="toc" aria-label="Table of contents">
        <%= render_toc(view) %>
      </aside>
      <main>
        <%= render_triage(view.triage, view.all_findings) %>
        <%= render_subjects(view.affected_subjects, view.adrs_by_id) %>
        <%= render_decisions_changed(view.decisions_changed) %>
        <%= render_unmapped(view.unmapped_changes) %>
      </main>
    </div>
    <footer class="page-footer">
      <span>specled_ex · spec.review</span>
    </footer>
    <script><%= js %></script>
  </body>
  </html>
  """, [:view, :css, :js])

  defp render_toc(view) do
    [
      ~S|<nav><ul class="toc-list">|,
      toc_item("triage", "Triage", triage_toc_badge(view.triage)),
      ~s|<li class="toc-section"><a href="#subjects">Affected subjects (#{view.triage.affected_subject_count})</a>|,
      if view.triage.affected_subjects == [] do
        ""
      else
        [
          ~S|<ul class="toc-sublist">|,
          Enum.map(view.triage.affected_subjects, fn s ->
            ~s|<li><a href="#subject-#{slug(s.id)}"><code>#{h(s.id)}</code>#{render_toc_finding_badge(s)}</a></li>|
          end),
          ~S|</ul>|
        ]
      end,
      ~S|</li>|,
      toc_item("decisions-changed", "Decisions changed (#{length(view.decisions_changed)})", ""),
      toc_item("misc", "Outside the spec system (#{length(view.unmapped_changes)})", ""),
      ~S|</ul></nav>|
    ]
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
      Map.get(by_sev, "error", 0) > 0 -> ~s| <span class="toc-pip toc-pip-error">#{count}</span>|
      Map.get(by_sev, "warning", 0) > 0 -> ~s| <span class="toc-pip toc-pip-warning">#{count}</span>|
      true -> ~s| <span class="toc-pip toc-pip-info">#{count}</span>|
    end
  end

  # covers: specled.spec_review.triage_panel
  # When clean? is true the panel collapses to a single confirmation row;
  # otherwise it summarizes finding count + severity breakdown + affected
  # subject count, lists each affected subject with its severity badge
  # (anchored to its card), and exposes a full findings list.
  defp render_triage(%{clean?: true}, _findings) do
    ~S"""
    <section id="triage" class="triage triage-clean" aria-label="Triage summary">
      <span class="triage-icon" aria-hidden="true">✓</span>
      <span class="triage-headline">No findings · no unmapped changes</span>
    </section>
    """
  end

  defp render_triage(triage, findings) do
    [
      ~S"""
      <section id="triage" class="triage" aria-label="Triage summary">
        <header class="triage-header">
          <h2>Triage</h2>
          <div class="triage-counts">
      """,
      render_severity_pill("error", Map.get(triage.by_severity, "error", 0)),
      render_severity_pill("warning", Map.get(triage.by_severity, "warning", 0)),
      render_severity_pill("info", Map.get(triage.by_severity, "info", 0)),
      ~s"""
            <span class="pill pill-neutral">#{triage.affected_subject_count} affected subjects</span>
      """,
      if triage.has_unmapped_changes? do
        ~s"""
              <span class="pill pill-neutral">unmapped changes present</span>
        """
      else
        ""
      end,
      ~S"""
          </div>
        </header>
      """,
      render_triage_subjects(triage.affected_subjects),
      render_findings_list(findings),
      ~S"""
      </section>
      """
    ]
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

  defp render_severity_pill(_severity, 0), do: ""

  defp render_severity_pill(severity, count) do
    ~s|<span class="pill pill-#{severity}">#{count} #{severity}</span>|
  end

  defp render_findings_list([]), do: ""

  defp render_findings_list(findings) do
    [
      ~S"""
      <details class="findings-list" open>
        <summary>All findings</summary>
        <ul>
      """,
      Enum.map(findings, fn f ->
        ~s"""
            <li class="finding-item finding-#{h(f["severity"])}">
              <span class="finding-severity">#{h(f["severity"])}</span>
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
          <%= SpecLedEx.Review.Html.render_subject_finding_badges(assigns[:s].findings) %>
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

  @doc false
  def render_spec_tab(s) do
    [
      render_requirements(s.requirements, s.findings),
      render_scenarios(s.scenarios),
      render_spec_diff(s.spec_diff)
    ]
  end

  defp render_requirements([], _), do: ""

  defp render_requirements(requirements, findings) do
    findings_by_req = group_findings_by_requirement(findings)

    [
      ~s|<h4 class="tab-heading">Requirements (#{length(requirements)})</h4>|,
      ~S|<ul class="requirement-list">|,
      Enum.map(requirements, fn req ->
        id = field(req, :id) || ""
        statement = field(req, :statement) || ""
        priority = field(req, :priority) || ""
        stability = field(req, :stability) || ""
        req_findings = Map.get(findings_by_req, id, [])

        ~s"""
        <li class="requirement">
          <div class="requirement-header">
            <code class="requirement-id">#{h(id)}</code>
            <span class="pill pill-priority pill-priority-#{h(priority)}">#{h(priority)}</span>
            <span class="pill pill-neutral">#{h(stability)}</span>
            #{render_requirement_finding_badge(req_findings)}
          </div>
          <p class="requirement-statement">#{h(statement)}</p>
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

  defp render_scenarios([]), do: ""

  defp render_scenarios(scenarios) do
    [
      ~s|<h4 class="tab-heading">Scenarios (#{length(scenarios)})</h4>|,
      ~S|<ul class="scenario-list">|,
      Enum.map(scenarios, fn sc ->
        id = field(sc, :id) || ""
        given = field(sc, :given) || []
        when_ = field(sc, :when) || []
        then_ = field(sc, :then) || []
        covers = field(sc, :covers) || []

        ~s"""
        <li class="scenario">
          <div class="scenario-header">
            <code class="scenario-id">#{h(id)}</code>
            #{Enum.map_join(covers, " ", fn c -> ~s|<span class="pill pill-cover">#{h(c)}</span>| end)}
          </div>
          <dl class="gherkin">
            #{render_gherkin_section("given", given)}
            #{render_gherkin_section("when", when_)}
            #{render_gherkin_section("then", then_)}
          </dl>
        </li>
        """
      end),
      ~S|</ul>|
    ]
  end

  defp render_gherkin_section(_, []), do: ""

  defp render_gherkin_section(label, items) do
    [
      ~s|<dt>#{label}</dt>|,
      Enum.map(items, fn item -> ~s|<dd>#{h(item)}</dd>| end)
    ]
  end

  defp render_spec_diff(nil), do: ""

  defp render_spec_diff(%{file: file, lines: lines}) do
    [
      ~s|<h4 class="tab-heading">Spec file changes</h4>|,
      ~s|<div class="filename"><code>#{h(file)}</code></div>|,
      render_diff_block(lines)
    ]
  end

  @doc false
  def render_code_tab(%{code_changes: []}) do
    ~S|<p class="empty-tab">No code files in this change set map to this subject.</p>|
  end

  def render_code_tab(%{code_changes: changes}) do
    Enum.map(changes, fn %{file: file, lines: lines} ->
      [
        ~s|<div class="code-change">|,
        ~s|<div class="filename"><code>#{h(file)}</code></div>|,
        render_diff_block(lines),
        ~S|</div>|
      ]
    end)
  end

  @doc false
  def render_coverage_tab(s) do
    bindings = s.bindings

    binding_section =
      if bindings == %{} or bindings == nil do
        ~S|<p class="empty-tab">No realized_by bindings declared on this subject.</p>|
      else
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

    verification_section =
      case s.verification do
        nil ->
          ""

        [] ->
          ""

        list when is_list(list) ->
          [
            ~s|<h4 class="tab-heading">Verification (#{length(list)})</h4>|,
            ~S|<ul class="verification-list">|,
            Enum.map(list, fn v ->
              kind = field(v, :kind) || ""
              target = field(v, :target) || ""
              covers = field(v, :covers) || []
              execute = field(v, :execute) || false

              ~s"""
              <li class="verification">
                <div class="verification-header">
                  <span class="pill pill-neutral">#{h(kind)}</span>
                  <code class="verification-target">#{h(target)}</code>
                  #{if execute, do: ~s|<span class="pill pill-success">executes</span>|, else: ~s|<span class="pill pill-muted">declared</span>|}
                </div>
                <div class="verification-covers">
                  #{Enum.map_join(covers, " ", fn c -> ~s|<span class="pill pill-cover">#{h(c)}</span>| end)}
                </div>
              </li>
              """
            end),
            ~S|</ul>|
          ]
      end

    [binding_section, verification_section]
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

    ~s"""
    <details class="adr">
      <summary class="adr-summary">
        <code class="adr-id">#{h(adr.id)}</code>
        <span class="adr-title">#{h(adr.title)}</span>
        #{status_pill}#{change_type_pill}#{date_chip}
      </summary>
      <div class="adr-body-wrap">
        <pre class="adr-body">#{h(adr.body_text)}</pre>
        #{if adr.file, do: ~s|<div class="adr-source"><code>#{h(adr.file)}</code></div>|, else: ""}
      </div>
    </details>
    """
  end

  defp render_decisions_changed([]) do
    ~S"""
    <section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">
      <h2 class="section-heading">Decisions changed (0)</h2>
      <p class="empty-tab">No ADR files changed in this change set.</p>
    </section>
    """
  end

  defp render_decisions_changed(decisions) do
    [
      ~s|<section id="decisions-changed" class="decisions-changed" aria-label="Decisions changed">|,
      ~s|<h2 class="section-heading">Decisions changed (#{length(decisions)})</h2>|,
      ~S|<ul class="decision-changed-list">|,
      Enum.map(decisions, fn d ->
        ~s"""
        <li>
          <code>#{h(d.id || d.file)}</code>
          #{if d.status, do: ~s|<span class="pill pill-neutral">#{h(d.status)}</span>|, else: ""}
          #{if d.change_type, do: ~s|<span class="pill pill-neutral">#{h(d.change_type)}</span>|, else: ""}
          #{if d.affects != [], do: ~s|<span class="affects">affects: #{Enum.map_join(d.affects, ", ", &h/1)}</span>|, else: ""}
        </li>
        """
      end),
      ~S|</ul>|,
      ~S|</section>|
    ]
  end

  defp render_unmapped([]) do
    ~S"""
    <section id="misc" class="misc" aria-label="Outside the spec system">
      <h2 class="section-heading">Outside the spec system (0)</h2>
      <p class="empty-tab">All file changes in this change set map to a spec subject.</p>
    </section>
    """
  end

  defp render_unmapped(changes) do
    [
      ~s|<section id="misc" class="misc" aria-label="Outside the spec system">|,
      ~s|<h2 class="section-heading">Outside the spec system (#{length(changes)})</h2>|,
      ~S|<p class="misc-explainer">These files changed but do not map to any spec subject. Triangulation does not apply here — review the diff directly.</p>|,
      Enum.map(changes, fn %{file: file, lines: lines} ->
        [
          ~s|<div class="misc-change">|,
          ~s|<div class="filename"><code>#{h(file)}</code></div>|,
          render_diff_block(lines),
          ~S|</div>|
        ]
      end),
      ~S|</section>|
    ]
  end

  defp render_diff_block([]) do
    ~S|<p class="empty-tab">(no diff content)</p>|
  end

  defp render_diff_block(lines) do
    [
      ~S|<pre class="diff"><code>|,
      Enum.map(lines, fn {kind, text} ->
        ~s|<span class="diff-line diff-#{kind}">#{h(text)}</span>\n|
      end),
      ~S|</code></pre>|
    ]
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  @doc false
  def h(nil), do: ""
  def h(value) when is_binary(value), do: html_escape(value)
  def h(value), do: value |> to_string() |> html_escape()

  defp html_escape(string) do
    string
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp slug(id) when is_binary(id), do: String.replace(id, ~r/[^a-z0-9]+/, "-")
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

    /* Triage */
    .triage {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 20px 24px;
    }
    .triage-clean {
      background: var(--success-bg);
      border-color: #c8e6c9;
      color: var(--success);
      display: flex;
      align-items: center;
      gap: 12px;
      font-weight: 500;
    }
    .triage-icon { font-size: 18px; font-weight: 700; }
    .triage-headline { font-size: 14px; }
    .triage-header { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
    .triage-header h2 { margin: 0; font-size: 18px; font-weight: 600; }
    .triage-counts { display: flex; gap: 8px; flex-wrap: wrap; }

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
    .gherkin {
      margin: 0;
      display: grid;
      grid-template-columns: 60px 1fr;
      gap: 4px 12px;
      font-size: 14px;
    }
    .gherkin dt {
      color: var(--fg-muted);
      font-weight: 600;
      text-transform: uppercase;
      font-size: 11px;
      letter-spacing: 0.05em;
      padding-top: 3px;
    }
    .gherkin dd { margin: 0; padding: 0; color: var(--fg); }

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
    .adr-body {
      background: var(--bg);
      border: 1px solid var(--border);
      border-radius: 4px;
      padding: 12px 14px;
      margin: 0;
      font-family: var(--body-font);
      font-size: 13px;
      line-height: 1.55;
      color: var(--fg);
      white-space: pre-wrap;
      word-wrap: break-word;
      max-height: 480px;
      overflow-y: auto;
    }
    .adr-source { padding-top: 6px; font-size: 11px; color: var(--fg-faint); text-align: right; }

    .decisions-changed {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
    }
    .decision-changed-list { list-style: none; margin: 0; padding: 0; }
    .decision-changed-list li {
      padding: 8px 0;
      display: flex;
      gap: 8px;
      align-items: center;
      flex-wrap: wrap;
      border-top: 1px solid var(--border);
      font-size: 13px;
    }
    .decision-changed-list li:first-child { border-top: none; }
    .affects { color: var(--fg-muted); font-size: 12px; }

    /* Misc panel */
    .misc {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
    }
    .misc-explainer { color: var(--fg-muted); margin: 0 0 16px 0; font-size: 13px; }
    .misc-change { margin-bottom: 16px; }
    .misc-change:last-child { margin-bottom: 0; }
    .code-change { margin-bottom: 16px; }
    .code-change:last-child { margin-bottom: 0; }
    .filename {
      background: var(--neutral-bg);
      padding: 6px 12px;
      border-radius: 4px 4px 0 0;
      font-size: 12px;
      border: 1px solid var(--border);
      border-bottom: none;
    }
    .filename code { font-family: var(--code-font); }

    /* Diff */
    .diff {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 0 0 4px 4px;
      margin: 0;
      padding: 8px 0;
      overflow-x: auto;
      font-family: var(--code-font);
      font-size: 12px;
      line-height: 1.45;
    }
    .diff code { display: block; }
    .diff-line { display: block; padding: 0 12px; white-space: pre; }
    .diff-add { background: var(--add-bg); color: var(--add-fg); }
    .diff-del { background: var(--del-bg); color: var(--del-fg); }
    .diff-hunk_header { background: var(--hunk-bg); color: var(--hunk-fg); font-weight: 500; padding-top: 4px; padding-bottom: 4px; }
    .diff-file_header { color: var(--fg-faint); }
    .diff-ctx { color: var(--fg); }

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
    """
  end
end
