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
          <%= render_subjects(view.affected_subjects, view.adrs_by_id) %>
          <%= render_decisions_changed(view.decisions_changed) %>
          <%= render_unmapped(view.unmapped_changes) %>
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
    open_attr = if triage.findings_count > 0, do: " open", else: ""
    summary = render_triage_summary(triage)

    [
      ~s|<details id="triage" class="triage" aria-label="Triage"#{open_attr}>|,
      ~s|<summary class="triage-summary-row">#{summary}</summary>|,
      ~S|<div class="triage-body">|,
      render_severity_pills_row(triage),
      render_triage_subjects(triage.affected_subjects),
      render_findings_list(findings),
      ~S"""
      </div>
      </details>
      """
    ]
  end

  defp render_triage_summary(triage) do
    affected_chunk =
      ~s|<span class="triage-summary-meta">#{triage.affected_subject_count} affected subject#{if triage.affected_subject_count == 1, do: "", else: "s"}</span>|

    unmapped_chunk =
      if triage.has_unmapped_changes? do
        ~s|<span class="triage-summary-meta">unmapped changes present</span>|
      end

    [triage_summary_findings_chunk(triage), affected_chunk, unmapped_chunk]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(~s|<span class="triage-summary-sep">·</span>|)
  end

  defp triage_summary_findings_chunk(%{findings_count: 0}) do
    ~S|<span class="triage-summary-pill triage-summary-clean">✓ no findings</span>|
  end

  defp triage_summary_findings_chunk(%{findings_count: n, by_severity: by_sev}) do
    cond do
      Map.get(by_sev, "error", 0) > 0 ->
        ~s|<span class="triage-summary-pill triage-summary-error">#{n} finding#{if n == 1, do: "", else: "s"}</span>|

      Map.get(by_sev, "warning", 0) > 0 ->
        ~s|<span class="triage-summary-pill triage-summary-warning">#{n} finding#{if n == 1, do: "", else: "s"}</span>|

      true ->
        ~s|<span class="triage-summary-pill triage-summary-info">#{n} finding#{if n == 1, do: "", else: "s"}</span>|
    end
  end

  defp render_severity_pills_row(triage) do
    pills =
      [
        render_severity_pill("error", Map.get(triage.by_severity, "error", 0)),
        render_severity_pill("warning", Map.get(triage.by_severity, "warning", 0)),
        render_severity_pill("info", Map.get(triage.by_severity, "info", 0))
      ]
      |> Enum.reject(&(&1 == ""))

    if pills == [] do
      ""
    else
      [~S|<div class="triage-counts">|, pills, ~S|</div>|]
    end
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

    [
      ~s|<h4 class="tab-heading">Requirements (#{length(requirements)})</h4>|,
      ~S|<ul class="requirement-list">|,
      Enum.map(requirements, fn req ->
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
      end),
      ~S|</ul>|
    ]
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
    [
      ~s|<h4 class="tab-heading">Scenarios (#{length(scenarios)})</h4>|,
      ~S|<ul class="scenario-list">|,
      Enum.map(scenarios, fn sc ->
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
      end),
      ~S|</ul>|
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
      render_coverage_help(),
      render_requirements_coverage(s.requirements, s.claims_by_req),
      render_bindings_section(s.bindings),
      render_verification_section(s.verification)
    ]
  end

  defp render_coverage_help do
    ~S"""
    <details class="coverage-help">
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

  defp render_verification_section(nil), do: ""
  defp render_verification_section([]), do: ""

  defp render_verification_section(list) when is_list(list) do
    [
      ~s|<details class="raw-verification">|,
      ~s|<summary class="raw-verification-summary">Raw spec-verification block (#{length(list)} entr#{if length(list) == 1, do: "y", else: "ies"})</summary>|,
      ~S|<p class="raw-verification-explainer">The author's declarations as written in the spec file. The per-requirement view above is computed from this.</p>|,
      ~S|<ul class="verification-list">|,
      Enum.map(list, fn v ->
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
      end),
      ~S|</ul>|,
      ~S|</details>|
    ]
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
    paths = Enum.map(changes, & &1.file)
    tree = build_path_tree(paths)

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
      ~S|<p class="misc-explainer">These files changed but do not map to any spec subject. Triangulation does not apply here — review the diff directly.</p>|,
      render_files_section(tree, "misc", "Files (#{length(paths)})", diff_blocks),
      ~S|</section>|
    ]
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

    /* Triage */
    .triage {
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 0;
    }
    .triage-clean {
      background: var(--success-bg);
      border-color: #c8e6c9;
      color: var(--success);
      display: flex;
      align-items: center;
      gap: 12px;
      font-weight: 500;
      padding: 16px 20px;
    }
    .triage-icon { font-size: 18px; font-weight: 700; }
    .triage-headline { font-size: 14px; }

    .triage-summary-row {
      list-style: none;
      cursor: pointer;
      padding: 14px 20px;
      display: flex;
      align-items: center;
      gap: 10px;
      flex-wrap: wrap;
      font-size: 14px;
    }
    .triage-summary-row::-webkit-details-marker { display: none; }
    .triage-summary-row::before {
      content: "▸";
      color: var(--fg-faint);
      font-size: 11px;
      width: 10px;
      flex-shrink: 0;
    }
    .triage[open] .triage-summary-row::before { content: "▾"; }
    .triage-summary-pill {
      display: inline-block;
      padding: 3px 12px;
      border-radius: 999px;
      font-size: 12px;
      font-weight: 600;
    }
    .triage-summary-clean { background: var(--success-bg); color: var(--success); }
    .triage-summary-error { background: var(--error-bg); color: var(--error); }
    .triage-summary-warning { background: var(--warning-bg); color: var(--warning); }
    .triage-summary-info { background: var(--info-bg); color: var(--info); }
    .triage-summary-meta { color: var(--fg-muted); font-size: 13px; }
    .triage-summary-sep { color: var(--fg-faint); }

    .triage-body { padding: 4px 20px 20px; border-top: 1px solid var(--border); }
    .triage-counts { display: flex; gap: 8px; flex-wrap: wrap; padding-top: 12px; }

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
       intact while letting Prism color the tokens inside .diff-content. */
    code.diff-content {
      display: inline;
      background: transparent !important;
      padding: 0 8px;
      margin: 0;
      border-radius: 0;
      font-family: var(--code-font);
      font-size: inherit;
      color: inherit;
      white-space: pre;
      text-shadow: none;
    }
    code.diff-content[class*="language-"] { tab-size: 2; }
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
    function closeAllTrees() {
      document.querySelectorAll('.files-section:not(.tree-collapsed)').forEach(function (s) {
        s.classList.add('tree-collapsed');
      });
    }

    document.addEventListener('click', function (e) {
      var openHandle = e.target.closest('[data-tree-action=\\"open\\"]');
      if (openHandle) {
        var section = openHandle.closest('.files-section');
        if (section) section.classList.remove('tree-collapsed');
        return;
      }
      var closeBtn = e.target.closest('[data-tree-action=\\"close\\"]');
      if (closeBtn) {
        var section = closeBtn.closest('.files-section');
        if (section) section.classList.add('tree-collapsed');
        return;
      }
      var leaf = e.target.closest('[data-tree-leaf]');
      if (leaf) {
        var section = leaf.closest('.files-section');
        if (section) section.classList.add('tree-collapsed');
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
