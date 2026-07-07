defmodule SpecLedEx.Review.HtmlLayoutTest do
  # Master–detail shell tests for the spec.review artifact.
  #
  # These pin the change/repo-state split introduced by
  # specled.decision.spec_review_change_scoped_master_detail: a left-rail
  # review queue, a change-scoped Overview pane, a repo-state Spec health
  # pane, findings deduped into (code, reason) digest rows, and theme-token
  # styling. Where a scenario is inherently runtime (theme persistence,
  # click-to-select), we pin the *mechanism* present in the rendered artifact
  # — the CSS token sets, the localStorage wiring, the fragment-addressable
  # panes — since ExUnit renders a string rather than driving a browser.

  use SpecLedEx.Case

  alias SpecLedEx.Review
  alias SpecLedEx.Review.Html

  # A repo with two affected subjects (auth.subject, billing.subject), both
  # with changed code files. Neither declares realized_by, so each yields a
  # synthetic no_realized_by detector_unavailable finding — giving us findings
  # to dedup and a degraded SPEC ↔ CODE leg on Spec health.
  defp two_subject_repo(root) do
    init_git_repo(root)

    write_subject_spec(root, "auth",
      meta: %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Auth boundary protects credentials.",
        "surface" => ["lib/auth.ex"]
      },
      requirements: [
        %{"id" => "auth.subject.req1", "statement" => "Must protect.", "priority" => "must"}
      ]
    )

    write_subject_spec(root, "billing",
      meta: %{
        "id" => "billing.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Billing computes invoices.",
        "surface" => ["lib/billing.ex"]
      },
      requirements: [
        %{"id" => "billing.subject.req1", "statement" => "Must total.", "priority" => "must"}
      ]
    )

    write_files(root, %{
      "lib/auth.ex" => "defmodule Auth do\nend\n",
      "lib/billing.ex" => "defmodule Billing do\nend\n"
    })

    commit_all(root, "initial")

    write_files(root, %{
      "lib/auth.ex" => "defmodule Auth do\n  def run, do: :ok\nend\n",
      "lib/billing.ex" => "defmodule Billing do\n  def total, do: 0\nend\n"
    })

    index = SpecLedEx.index(root)
    view = Review.build_view(index, root, base: "main")
    {view, IO.iodata_to_binary(Html.render(view))}
  end

  # Extract the inner HTML of one detail pane by its data-unit, up to the next
  # detail-pane or the end of <main>.
  defp pane(html, unit) do
    pattern =
      "<section class=\"detail-pane[^\"]*\" data-unit=\"" <>
        Regex.escape(unit) <>
        "\"[^>]*>(.*?)(?=<section class=\"detail-pane|</main>)"

    re = Regex.compile!(pattern, "s")

    case Regex.run(re, html, capture: :all_but_first) do
      [inner] -> inner
      _ -> flunk("no detail pane for unit #{unit}")
    end
  end

  # Extract one subject pivot panel (spec-/code-/coverage-/decisions-<slug>) by
  # its id. Pivot panels contain no nested <section>, so a non-greedy match to
  # the next </section> isolates exactly one panel.
  defp tab_panel(html, id) do
    re =
      Regex.compile!(
        "<section class=\"tab-panel[^\"]*\" id=\"" <>
          Regex.escape(id) <> "\"[^>]*>(.*?)</section>",
        "s"
      )

    case Regex.run(re, html, capture: :all_but_first) do
      [inner] -> inner
      _ -> flunk("no tab panel #{id}")
    end
  end

  defp at(haystack, needle), do: elem(:binary.match(haystack, needle), 0)

  describe "review queue navigation (specled.spec_review.review_queue_navigation)" do
    @tag spec: "specled.spec_review.review_queue_navigation"
    test "queue lists every reviewable unit and each is a deep-linkable pane", %{root: root} do
      {_view, html} = two_subject_repo(root)

      # Every fixed unit renders both a queue row and a matching detail pane.
      for unit <- ~w(overview decisions misc files health) do
        assert html =~ ~s|data-unit="#{unit}"|
        assert html =~ ~s|href="#unit-#{unit}"|
        assert html =~ ~s|id="unit-#{unit}"|
      end
    end

    @tag spec: "specled.spec_review.review_queue_navigation"
    test "each affected subject has a queue row and its own detail pane, deep-linkable by fragment",
         %{root: root} do
      {_view, html} = two_subject_repo(root)

      for id <- ~w(auth.subject billing.subject) do
        slug = id |> String.downcase() |> String.replace(".", "-")
        # Queue row links to the subject's pane fragment.
        assert html =~ ~s|href="#unit-subject-#{slug}"|
        assert html =~ ~s|data-subject-id="#{id}"|
        # The detail pane exists and is addressable by that fragment.
        assert html =~ ~s|data-unit="subject-#{slug}"|
        assert html =~ ~s|id="unit-subject-#{slug}"|
      end
    end

    @tag spec: "specled.spec_review.review_queue_navigation"
    test "exactly one pane (Overview) is active by default so a single unit shows at a time",
         %{root: root} do
      {_view, html} = two_subject_repo(root)

      active_panes = Regex.scan(~r|<section class="detail-pane active"|, html)
      assert length(active_panes) == 1

      # And the one active pane is Overview.
      assert html =~ ~r|<section class="detail-pane active" data-unit="overview"|
    end

    @tag spec: "specled.spec_review.review_queue_navigation"
    test "the queue groups subjects by change kind with a finding dot, spec chip slot, and file count",
         %{root: root} do
      {_view, html} = two_subject_repo(root)

      queue =
        Regex.run(~r|<aside class="queue"[^>]*>(.*?)</aside>|s, html, capture: :all_but_first)
        |> hd()

      assert queue =~ ~s|class="queue-group-label"|
      assert queue =~ ~s|class="queue-dot|
      assert queue =~ ~s|class="queue-filecount"|
      assert queue =~ ~s|class="queue-filter"|
    end

    @tag spec: "specled.spec_review.review_queue_navigation"
    test "the page wires fragment-driven selection and j/k navigation", %{root: root} do
      {_view, html} = two_subject_repo(root)

      # Selection is driven by the URL fragment (deep-linkable) and marks the
      # current queue row; j/k move through the queue.
      assert html =~ "hashchange"
      assert html =~ "queue-current"
      assert html =~ "aria-current"
      assert html =~ "e.key === 'j'"
    end
  end

  describe "change-scoped Overview vs repo-state Spec health" do
    @tag spec: "specled.spec_review.change_scoped_overview"
    test "Overview shows change-scoped counts and omits the triangle and whole-repo inventories",
         %{root: root} do
      {_view, html} = two_subject_repo(root)
      overview = pane(html, "overview")

      # Change-scoped tiles present.
      assert overview =~ "Subjects touched"
      assert overview =~ "Spec requirements edited"
      assert overview =~ "Decisions changed"
      assert overview =~ "Unmapped files"

      # The sync triangle and whole-repo strength/inventory do NOT render here.
      refute overview =~ "sync-edge"
      refute overview =~ "strength-inventory"
      refute overview =~ "repo-inventory"
    end

    @tag spec: "specled.spec_review.repo_state_health_pane"
    test "Spec health holds the triangle, strength inventory, and full findings under a head-ref heading",
         %{root: root} do
      {view, html} = two_subject_repo(root)
      health = pane(html, "health")

      assert health =~ "sync-edge"
      assert health =~ "strength-inventory"
      assert health =~ "findings-digest"
      # Heading explicitly labels the content as repo state at the head ref.
      assert health =~ "repo state at"
      assert health =~ view.meta.head_ref
    end
  end

  describe "findings digest dedup (specled.spec_review.findings_digest_dedup)" do
    @tag spec: "specled.spec_review.findings_digest_dedup"
    test "23 findings sharing (code, reason) across 23 subjects render one row with count 23", %{
      root: _root
    } do
      findings =
        for n <- 1..23 do
          %{
            "code" => "detector_unavailable",
            "reason" => "no_realized_by",
            "severity" => "info",
            "subject_id" => "subject.#{n}",
            "message" => "no realized_by on subject.#{n}"
          }
        end

      html = IO.iodata_to_binary(Html.render_findings_digest(findings))

      # Exactly one digest row for the (code, reason) pair.
      assert length(Regex.scan(~r|findings-digest-row|, html)) == 1
      assert html =~ ~s|<code class="findings-digest-code">detector_unavailable</code>|
      assert html =~ "no_realized_by"
      assert html =~ "×23"

      # Expanding lists all 23 affected subjects as links to their queue entries.
      assert html =~ "23 subjects"
      assert html =~ ~s|href="#unit-subject-subject-1"|
      assert html =~ ~s|href="#unit-subject-subject-23"|
    end

    @tag spec: "specled.spec_review.findings_digest_dedup"
    test "distinct (code, reason) pairs render as distinct rows", %{root: _root} do
      findings = [
        %{"code" => "a_code", "reason" => "r1", "severity" => "error", "subject_id" => "s.1"},
        %{"code" => "a_code", "reason" => "r2", "severity" => "warning", "subject_id" => "s.2"}
      ]

      html = IO.iodata_to_binary(Html.render_findings_digest(findings))
      assert length(Regex.scan(~r|findings-digest-row|, html)) == 2
    end
  end

  describe "theme tokens (specled.spec_review.theme_tokens)" do
    @tag spec: "specled.spec_review.theme_tokens"
    test "the artifact ships light and dark token sets with a prefers-color-scheme default", %{
      root: root
    } do
      {_view, html} = two_subject_repo(root)

      # Light values live on :root; a dark set is gated on the OS preference.
      assert html =~ ":root {"
      assert html =~ "@media (prefers-color-scheme: dark)"
      # The dark set is applied only when the viewer has not forced light.
      assert html =~ ~s|:root:not([data-theme="light"])|
    end

    @tag spec: "specled.spec_review.theme_tokens"
    test "a three-state toggle overrides the default and persists to localStorage", %{root: root} do
      {_view, html} = two_subject_repo(root)

      for choice <- ~w(system light dark) do
        assert html =~ ~s|data-theme-choice="#{choice}"|
      end

      # Forcing dark/light is a data-theme override on the root element.
      assert html =~ ~s|:root[data-theme="dark"]|
      # The choice is persisted and re-applied across reloads.
      assert html =~ "localStorage.setItem('specled-theme'"
      assert html =~ "localStorage.getItem('specled-theme')"
    end

    @tag spec: "specled.spec_review.theme_tokens"
    test "all surfaces flow through custom-property tokens (no raw body colors)", %{root: root} do
      {_view, html} = two_subject_repo(root)

      # The token contract: body paints from var() tokens, not literal hex.
      assert html =~ "background: var(--bg); color: var(--fg)"
    end
  end

  describe "verdict chip + clean change (specled.spec_review.triage_panel)" do
    @tag spec: "specled.spec_review.triage_panel"
    test "a clean change reads clean: chip + Overview headline, no severity counts", %{root: root} do
      init_git_repo(root)

      write_subject_spec(root, "auth",
        meta: %{
          "id" => "auth.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Auth.",
          "surface" => ["lib/auth.ex"],
          "realized_by" => %{"implementation" => ["Auth.run/0"]}
        }
      )

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\n  def run, do: :ok\nend\n"})
      # Commit a base-side findings state so the delta is differential; with no
      # findings at base and none introduced at head the verdict is clean.
      write_files(root, %{".spec/state.json" => Jason.encode!(%{"findings" => []})})
      commit_all(root, "initial")

      # A change set that touches the subject's code but introduces no findings.
      write_files(root, %{
        "lib/auth.ex" => "defmodule Auth do\n  # touched\n  def run, do: :ok\nend\n"
      })

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")

      # Differential and clean: zero findings introduced by the change.
      assert view.findings_delta.change_verdict.differential? == true
      assert view.findings_delta.change_verdict.clean? == true

      html = IO.iodata_to_binary(Html.render(view))

      assert html =~ "verdict-chip-clean"
      overview = pane(html, "overview")
      assert overview =~ "introduces no findings"
      refute overview =~ "overview-sev-error"
    end

    @tag spec: "specled.spec_review.degraded_leg_state"
    test "a degraded leg renders neutral with a ? glyph and a partial badge, not the change verdict",
         %{root: root} do
      {view, html} = two_subject_repo(root)
      health = pane(html, "health")

      # Degraded SPEC ↔ CODE leg (no_realized_by) renders with ? not ✓/✗.
      assert health =~ ~s|sync-edge sync-edge-degraded|
      assert Regex.match?(~r|sync-edge-degraded.*?sync-edge-icon">\?</span>|s, health)

      # The queue badge advertises partial verification.
      assert html =~ "queue-badge-degraded"

      # Degraded repo state does not flip the change verdict chip to a failure.
      # Inspect the actual chip element (the CSS always names every modifier).
      [chip_modifier] =
        Regex.run(~r/<span class="verdict-chip (verdict-chip-[a-z]+)"/, html,
          capture: :all_but_first
        )

      refute chip_modifier == "verdict-chip-error"
      assert view.findings_delta.change_verdict.differential? == false
    end
  end

  describe "coverage pivot touched-first (specled.spec_review.coverage_pivot_touched_first)" do
    # Base: subject S with two requirements. Change: a third requirement is
    # added to the same subject, leaving the first two untouched — the
    # coverage_pivot_leads_with_touched scenario's given clause.
    defp added_requirement_repo(root) do
      init_git_repo(root)

      base_meta = %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Auth boundary protects credentials.",
        "surface" => ["lib/auth.ex"]
      }

      write_subject_spec(root, "auth",
        meta: base_meta,
        requirements: [
          %{"id" => "auth.subject.req1", "statement" => "Must protect.", "priority" => "must"},
          %{"id" => "auth.subject.req2", "statement" => "Must audit.", "priority" => "must"}
        ]
      )

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "initial")

      # The PR adds req_new to the subject and leaves the other two untouched.
      write_subject_spec(root, "auth",
        meta: base_meta,
        requirements: [
          %{"id" => "auth.subject.req1", "statement" => "Must protect.", "priority" => "must"},
          %{"id" => "auth.subject.req2", "statement" => "Must audit.", "priority" => "must"},
          %{
            "id" => "auth.subject.req_new",
            "statement" => "Must rotate keys.",
            "priority" => "must"
          }
        ]
      )

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")
      {view, IO.iodata_to_binary(Html.render(view))}
    end

    # Isolate one subject's Coverage tab panel from the full artifact.
    defp coverage_tab(html, slug) do
      re =
        Regex.compile!(
          "<section class=\"tab-panel\" id=\"coverage-" <>
            Regex.escape(slug) <> "\"[^>]*>(.*?)</section>",
          "s"
        )

      case Regex.run(re, html, capture: :all_but_first) do
        [inner] -> inner
        _ -> flunk("no coverage tab for #{slug}")
      end
    end

    defp index_of(haystack, needle), do: elem(:binary.match(haystack, needle), 0)

    @tag spec: "specled.spec_review.coverage_pivot_touched_first"
    test "the added requirement leads the Coverage pivot; untouched ones fold behind an unchanged-from-base disclosure",
         %{root: root} do
      {_view, html} = added_requirement_repo(root)
      coverage = coverage_tab(html, "auth-subject")

      # The added requirement renders with its ADDED change chip and a strength
      # badge (the scenario's "R1 renders first with its ADDED change chip and
      # strength").
      assert coverage =~ "auth.subject.req_new"
      assert coverage =~ ~r|cov-req cov-req-\w+ cov-req-new|
      assert coverage =~ "ADDED"
      assert coverage =~ "strength-badge"

      # Untouched requirements fold behind a disclosure stating their strength
      # is unchanged from base.
      assert coverage =~ "cov-unchanged-disclosure"
      assert coverage =~ "whose strength is unchanged from base"

      # Touched-first ordering: the added requirement precedes the disclosure,
      # and the untouched requirements sit inside (after) it. Under the old
      # flat-list rendering req1 preceded req_new and no disclosure existed, so
      # this ordering is what makes the assertion falsifiable.
      added_at = index_of(coverage, "auth.subject.req_new")
      fold_at = index_of(coverage, "whose strength is unchanged from base")
      untouched_at = index_of(coverage, "auth.subject.req1")

      assert added_at < fold_at
      assert fold_at < untouched_at
    end

    @tag spec: "specled.spec_review.coverage_pivot_touched_first"
    test "a change set that touches no requirement folds the whole coverage list as unchanged from base",
         %{root: _root} do
      # No spec_changes key at all: every requirement is untouched and the whole
      # list collapses behind the disclosure rather than rendering open.
      subject = %{
        id: "subj.a",
        bindings: %{},
        requirements: [
          %{"id" => "subj.a.req1", "statement" => "One.", "priority" => "must"},
          %{"id" => "subj.a.req2", "statement" => "Two.", "priority" => "must"}
        ],
        claims_by_req: %{},
        closure_reach: %{status: :ok, by_requirement: %{}}
      }

      html = IO.iodata_to_binary(Html.render_coverage_tab(subject))

      assert html =~ "cov-unchanged-disclosure"
      assert html =~ "Show 2 requirements whose strength is unchanged from base"
      # Requirements are still present (inside the fold), not dropped.
      assert html =~ "subj.a.req1"
      assert html =~ "subj.a.req2"
      # No requirement is marked touched.
      refute html =~ "cov-req-new"
      refute html =~ "cov-req-modified"
    end
  end

  describe "Code pivot grouped by binding tier (specled.spec_review.per_subject_tabs)" do
    # A subject declaring MFAs in both the api_boundary and implementation tiers,
    # with code changes touching a file that resolves to each tier — the
    # code_tab_grouped_by_binding scenario's given clause.
    defp two_tier_subject do
      %{
        id: "auth.subject",
        bindings: %{
          "api_boundary" => ["Auth.Boundary.check/1"],
          "implementation" => ["Auth.Impl.run/0"]
        },
        code_changes: [
          %{file: "lib/auth/boundary.ex", lines: [{:add, "def check(x), do: x"}]},
          %{file: "lib/auth/impl.ex", lines: [{:add, "def run, do: :ok"}]}
        ]
      }
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "code changes are grouped under realized_by tier headers, files nested under each tier" do
      html = IO.iodata_to_binary(Html.render_code_tab(two_tier_subject()))

      # Both tiers render as headed groups (not a flat file tree).
      assert html =~ ~s|data-tier="api_boundary"|
      assert html =~ ~s|data-tier="implementation"|
      assert html =~ "API boundary"
      assert html =~ "Implementation"

      # The file that resolves to each tier sits under that tier's header rather
      # than being organized by path first. Ordering proves attribution: the
      # api_boundary group (with boundary.ex) fully precedes the implementation
      # group (with impl.ex). Under the old flat build there were no tier
      # headers at all, so this is the falsifiable condition.
      api_at = at(html, ~s|data-tier="api_boundary"|)
      boundary_at = at(html, "lib/auth/boundary.ex")
      impl_tier_at = at(html, ~s|data-tier="implementation"|)
      impl_at = at(html, "lib/auth/impl.ex")

      assert api_at < boundary_at
      assert boundary_at < impl_tier_at
      assert impl_tier_at < impl_at
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "a changed file matching no declared binding falls into an Other group, not dropped" do
      subject = %{
        id: "auth.subject",
        bindings: %{"implementation" => ["Auth.Impl.run/0"]},
        code_changes: [
          %{file: "lib/auth/impl.ex", lines: [{:add, "def run, do: :ok"}]},
          %{file: "lib/auth/helpers.ex", lines: [{:add, "def util, do: :ok"}]}
        ]
      }

      html = IO.iodata_to_binary(Html.render_code_tab(subject))

      assert html =~ ~s|data-tier="implementation"|
      assert html =~ ~s|code-tier-other|
      assert html =~ "Other changed files"
      # The unmatched file is still rendered (under Other), never silently dropped.
      assert html =~ "lib/auth/helpers.ex"
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "a subject with no bindings degrades to a flat file diff with an explanatory note" do
      subject = %{
        id: "auth.subject",
        bindings: %{},
        code_changes: [%{file: "lib/auth.ex", lines: [{:add, "def run, do: :ok"}]}]
      }

      html = IO.iodata_to_binary(Html.render_code_tab(subject))

      assert html =~ "code-flat-note"
      assert html =~ "declares no"
      assert html =~ "flat file diff"
      # No tier grouping when there are no bindings to group by.
      refute html =~ "data-tier="
      assert html =~ "lib/auth.ex"
    end
  end

  describe "file diff collapse for deletions and oversized diffs (specled.spec_review.diff_against_base)" do
    defp flat_subject(file, lines) do
      %{id: "auth.subject", bindings: %{}, code_changes: [%{file: file, lines: lines}]}
    end

    @tag spec: "specled.spec_review.diff_against_base"
    test "a small diff renders expanded" do
      html =
        IO.iodata_to_binary(
          Html.render_code_tab(flat_subject("lib/auth.ex", [{:add, "+def run, do: :ok"}]))
        )

      assert html =~ ~r/<details class="code-change"[^>]* open>/
      refute html =~ "code-change-note"
    end

    @tag spec: "specled.spec_review.diff_against_base"
    test "a full-file deletion renders collapsed with a deletion note" do
      lines = [
        {:file_header, "diff --git a/lib/gone.ex b/lib/gone.ex"},
        {:file_header, "deleted file mode 100644"},
        {:del, "-defmodule Gone do"},
        {:del, "-end"}
      ]

      html = IO.iodata_to_binary(Html.render_code_tab(flat_subject("lib/gone.ex", lines)))

      refute html =~ ~r/<details class="code-change"[^>]* open>/
      assert html =~ "file deleted · 2 lines"
      # The deletion body is still present behind the fold, not dropped.
      assert html =~ "defmodule Gone do"
    end

    @tag spec: "specled.spec_review.diff_against_base"
    test "a diff above the size threshold renders collapsed with a large-diff note" do
      lines = Enum.map(1..401, fn n -> {:add, "+line #{n}"} end)

      html = IO.iodata_to_binary(Html.render_code_tab(flat_subject("lib/big.ex", lines)))

      refute html =~ ~r/<details class="code-change"[^>]* open>/
      assert html =~ "large diff · 401 lines"
    end
  end

  describe "header diffstat info popover (specled.spec_review.diff_against_base)" do
    @tag spec: "specled.spec_review.diff_against_base"
    test "explains that tool-managed spec state files are excluded from the counts" do
      html =
        IO.iodata_to_binary(
          Html.render_diff_stats(%{files_changed: 3, additions: 10, deletions: 4})
        )

      assert html =~ "diffstat-info"
      assert html =~ ".spec/state.json"
      assert html =~ "excluded"
    end
  end

  describe "per-subject pivot labels, default, and de-emphasis (specled.spec_review.per_subject_tabs)" do
    # A subject whose code changed: three requirements untouched, two ADRs.
    defp code_changed_subject do
      %{
        id: "s.a",
        statement: "x",
        bindings: %{},
        code_changes: [%{file: "lib/a.ex", lines: [{:add, "x"}]}],
        diffstat: %{adds: 3, dels: 1},
        requirements: [%{"id" => "s.a.r1", "statement" => "One.", "priority" => "must"}],
        scenarios: [],
        decision_refs: [],
        findings: [],
        claims_by_req: %{},
        closure_reach: %{status: :ok, by_requirement: %{}},
        spec_diff: nil,
        spec_changes: %{
          file_changed?: false,
          base_existed?: true,
          requirements: %{added: [], modified: [], removed: []},
          scenarios: %{added: [], modified: [], removed: []}
        }
      }
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "each pivot label carries a change-scoped summary" do
      html = IO.iodata_to_binary(Html.render_subject_pivots(code_changed_subject(), "s-a", %{}))

      # Code: file count + diffstat. Spec/Coverage: unchanged. Decisions: empty.
      assert html =~ "Code · 1 file +3/−1"
      assert html =~ "Spec · unchanged"
      assert html =~ "Coverage · no change"
      # Decisions has no refs, so it reads bare and is de-emphasized.
      assert html =~
               ~r|<button class="tab tab-empty"[^>]*data-tab="decisions-s-a"[^>]*title="No ADRs referenced|
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "the default pivot is Code when this subject's code changed" do
      html = IO.iodata_to_binary(Html.render_subject_pivots(code_changed_subject(), "s-a", %{}))

      # Exactly one tab and one panel are active, and they are Code.
      assert length(Regex.scan(~r|<button class="tab active"|, html)) == 1
      assert html =~ ~r|<button class="tab active"[^>]*data-tab="code-s-a"|
      assert html =~ ~r|<section class="tab-panel active" id="code-s-a"|
      refute html =~ ~r|<section class="tab-panel active" id="spec-s-a"|
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "the default pivot is Spec when only the spec changed, and empty Code is de-emphasized" do
      subject = %{
        code_changed_subject()
        | code_changes: [],
          diffstat: %{adds: 0, dels: 0},
          spec_changes: %{
            file_changed?: true,
            base_existed?: true,
            requirements: %{
              added: [%{"id" => "s.a.r2", "statement" => "New.", "priority" => "must"}],
              modified: [],
              removed: []
            },
            scenarios: %{added: [], modified: [], removed: []}
          }
      }

      html = IO.iodata_to_binary(Html.render_subject_pivots(subject, "s-a", %{}))

      assert html =~ ~r|<button class="tab active"[^>]*data-tab="spec-s-a"|
      assert html =~ ~r|<section class="tab-panel active" id="spec-s-a"|
      # Change-scoped labels reflect the spec edit.
      assert html =~ "Spec · +1"
      assert html =~ "Coverage · 1 touched"
      # Code has no changes: bare label + de-emphasis with a reason.
      assert html =~
               ~r|<button class="tab tab-empty"[^>]*data-tab="code-s-a"[^>]*title="No code files|
    end
  end

  describe "subject header (specled.spec_review.spec_first_navigation)" do
    @tag spec: "specled.spec_review.spec_first_navigation"
    test "a long prose statement is clamped with a pure-CSS expand toggle" do
      long = String.duplicate("credential rotation policy ", 12)
      html = IO.iodata_to_binary(Html.render_subject_statement(long, "s-a"))

      assert html =~ "subject-statement-clamped"
      assert html =~ ~s|id="stmt-s-a"|
      assert html =~ "statement-toggle"
      assert html =~ ~s|<label class="statement-expand" for="stmt-s-a">|
    end

    @tag spec: "specled.spec_review.spec_first_navigation"
    test "a short statement renders plainly with no expand toggle" do
      html = IO.iodata_to_binary(Html.render_subject_statement("Short and sweet.", "s-b"))

      assert html =~ ~s|<p class="subject-statement">Short and sweet.</p>|
      refute html =~ "statement-toggle"
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "per-subject triangle leg chips reflect the subject's own findings" do
      # A no_realized_by detector_unavailable finding degrades SPEC ↔ CODE; an
      # observed-coverage error fails CODE ↔ TESTS; SPEC ↔ TESTS stays ok.
      findings = [
        %{"code" => "detector_unavailable", "reason" => "no_realized_by", "severity" => "info"},
        %{"code" => "branch_guard_untethered_test", "severity" => "error"}
      ]

      html = IO.iodata_to_binary(Html.render_subject_leg_chips(findings))

      assert html =~ "subject-legs"
      assert html =~ ~r|leg-chip-degraded"[^>]*>Spec ↔ Code|
      assert html =~ ~r|leg-chip-ok"[^>]*>Spec ↔ Tests|
      assert html =~ ~r|leg-chip-fail"[^>]*>Code ↔ Tests|
    end
  end

  describe "Spec pivot semantic diff (specled.spec_review.per_subject_tabs)" do
    defp modified_requirement_repo(root) do
      init_git_repo(root)

      base_meta = %{
        "id" => "auth.subject",
        "kind" => "module",
        "status" => "active",
        "summary" => "Auth boundary protects credentials.",
        "surface" => ["lib/auth.ex"]
      }

      write_subject_spec(root, "auth",
        meta: base_meta,
        requirements: [
          %{
            "id" => "auth.subject.req1",
            "statement" => "Legacy wording here.",
            "priority" => "must"
          }
        ]
      )

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "initial")

      write_subject_spec(root, "auth",
        meta: base_meta,
        requirements: [
          %{
            "id" => "auth.subject.req1",
            "statement" => "Updated phrasing here.",
            "priority" => "must"
          }
        ]
      )

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")
      {view, IO.iodata_to_binary(Html.render(view))}
    end

    @tag spec: "specled.spec_review.per_subject_tabs"
    test "a modified requirement renders inline wording del/ins and the raw file diff folds away",
         %{root: root} do
      {_view, html} = modified_requirement_repo(root)
      spec = tab_panel(html, "spec-auth-subject")

      # The requirement is flagged MODIFIED and its wording shows both a deletion
      # and an insertion inline (base -> head). Under the old rendering the head
      # statement rendered plainly, so the del/ins markup is the falsifiable bit.
      assert spec =~ "MODIFIED"
      assert spec =~ ~s|<del class="wording-del">|
      assert spec =~ ~s|<ins class="wording-ins">|

      # The line-level file diff is behind a fold rather than an open heading.
      assert spec =~ "spec-diff-fold"
      assert spec =~ "Raw spec file diff"
      refute spec =~ "<h4 class=\"tab-heading\">Spec file changes</h4>"
    end
  end
end
