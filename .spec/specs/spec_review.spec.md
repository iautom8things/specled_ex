# Spec Review

A self-contained HTML artifact that turns a Git change set into a spec-aware PR review surface.

## Intent

Render the structured triangulation that specled_ex already produces (spec ↔ binding ↔ test ↔ coverage) as a human review surface, so the rigor that today exists only as a CI gate becomes legible during the act of review. Reviewers see intent first (the spec's prose statement), then pivot to code, tests, coverage, and decisions from the same anchor. Changes that don't map to any subject are surfaced honestly in a labeled "outside the spec system" panel rather than hidden.

The artifact is organized as a review queue: a master–detail layout whose left rail lists every reviewable unit and whose detail pane shows one unit at a time. Information about **this change** (the diff, spec edits, findings the change introduces) is kept strictly separate from **repo state at head** (whole-repo verification, strength inventories, pre-existing findings) — mixing the two was the primary legibility failure of the v1 layout. See `specled.decision.spec_review_change_scoped_master_detail`.

The artifact is read-only in v1. Acceptance still happens via the host platform's existing approval flow (e.g., GitHub's Approve button); the artifact's job is to make that approval informed, not to record it.

```spec-meta
id: specled.spec_review
kind: workflow
status: active
summary: Renders a Git change set as a self-contained HTML PR review surface. Master–detail review queue keyed on spec subjects, change-scoped Overview pane with differential findings, separate repo-state Spec health pane, per-subject pivots (Spec / Code / Coverage / Decisions), theme-aware. Same artifact runs locally and in CI.
surface:
  - lib/mix/tasks/spec.review.ex
  - lib/specled_ex/review.ex
  - lib/specled_ex/review/file_diff.ex
  - lib/specled_ex/review/html.ex
  - lib/specled_ex/review/spec_diff.ex
  - priv/spec_review_assets/*
  - test/specled_ex/review_test.exs
  - test/specled_ex/review/html_test.exs
  - test/mix/tasks/spec_review_task_test.exs
decisions:
  - specled.decision.spec_review_html_viewer
  - specled.decision.spec_review_change_scoped_master_detail
```

## Requirements

```spec-requirements
- id: specled.spec_review.html_artifact
  statement: mix spec.review shall produce a self-contained HTML file with all CSS and JavaScript embedded so the artifact renders correctly without any external network resources at view time.
  priority: must
  stability: evolving
- id: specled.spec_review.spec_first_navigation
  statement: The HTML shall organize content by spec subject as the primary unit, with each affected subject's detail headlined by the subject's human-readable prose statement rather than its raw YAML or file path.
  priority: must
  stability: evolving
- id: specled.spec_review.review_queue_navigation
  statement: >-
    The HTML shall render a master–detail layout: a left-rail review queue
    listing every reviewable unit (Overview, Decisions changed, each affected
    subject, the outside-the-spec-system panel, the all-files view, and Spec
    health), and a detail pane rendering exactly one selected unit at a time.
    Subject rows shall be grouped by change kind (spec edited / code only /
    impacted only), ordered within each group by change size, and shall carry
    a finding indicator, a spec-change chip, and a changed-file count. The
    queue shall be filterable by subject id, and selecting a unit shall update
    the URL fragment so any unit is deep-linkable.
  priority: must
  stability: evolving
- id: specled.spec_review.change_scoped_overview
  statement: >-
    The landing detail pane (Overview) shall present only change-scoped
    information: the change verdict, diff-scoped counts (subjects touched,
    spec requirements edited, decisions changed, unmapped files), the spec
    edits in the change set, the findings delta, the mapped/policy/unmapped
    file breakdown, and changed decisions. Whole-repo inventories
    (requirement, binding, and verification counts; coverage strength
    totals) and whole-repo verification state (the triangle diagram and its
    per-leg checks) shall not render on the Overview pane.
  priority: must
  stability: evolving
- id: specled.spec_review.repo_state_health_pane
  statement: >-
    Whole-repo verification state — the sync triangle with per-leg states,
    the per-leg check lists, coverage strength inventories, and the full
    findings inventory — shall render on a dedicated Spec health pane whose
    heading explicitly labels the content as repo state at the head ref and
    not attributable to the change set under review.
  priority: must
  stability: evolving
- id: specled.spec_review.findings_delta
  statement: >-
    The Overview pane shall classify findings differentially as introduced
    (present at head, absent at base), resolved (present at base, absent at
    head), and pre-existing (present at both), computing the base-side
    finding set from the committed verification state at the base ref
    (`git show <base>:.spec/state.json`). The change verdict shall be
    driven by introduced findings only. When the base state file is absent
    or unparseable the artifact shall fall back to a non-differential
    presentation that is explicitly labeled as such — findings shall never
    be silently presented as introduced by the change when base attribution
    is unavailable.
  priority: must
  stability: evolving
- id: specled.spec_review.findings_digest_dedup
  statement: >-
    Findings lists on the Overview and Spec health panes shall group
    findings by (code, reason) into a single digest row carrying the
    severity, the occurrence count, and an expandable list of affected
    subjects linking to their queue entries — never one visually identical
    row per finding instance.
  priority: must
  stability: evolving
- id: specled.spec_review.per_subject_tabs
  statement: >-
    Each subject's detail pane shall expose four pivots — Spec, Code,
    Coverage, and Decisions — that pivot from the subject's intent to its
    supporting artifacts. The Code pivot shall organize changes by
    realized_by binding tier rather than by file path. Each pivot label
    shall carry a change-scoped summary (file count and diffstat for Code;
    added/modified requirement counts for Spec; touched-requirement count
    for Coverage; reference count for Decisions). The default-selected
    pivot shall be the one carrying this change set's edits (Code when code
    changed; Spec when only the spec changed), and pivots with no content
    shall render visibly de-emphasized with the reason available.
  priority: must
  stability: evolving
- id: specled.spec_review.triage_panel
  statement: >-
    The artifact shall render a persistent change-verdict chip in the top
    bar and shall land on the Overview pane. The verdict chip and the
    Overview headline shall state the change-scoped verdict: the count and
    severity of findings introduced by the change set, or a clean
    confirmation when the change introduces none. A change set that
    introduces zero findings shall read as clean even when pre-existing
    findings or degraded verification exist at head, so clean change sets
    feel clean.
  priority: must
  stability: evolving
- id: specled.spec_review.inline_finding_badges
  statement: Findings affecting a subject shall additionally render as inline badges on that subject's queue row and detail pane, in addition to appearing in the findings digest.
  priority: must
  stability: evolving
- id: specled.spec_review.theme_tokens
  statement: >-
    The artifact shall style all surfaces through CSS custom-property
    tokens with both a light and a dark value set. The rendered theme
    shall default to the viewer's prefers-color-scheme, and a three-state
    toggle (system / light / dark) shall override it, persisting the
    choice in localStorage across reloads. Theme switching shall require
    no network resources, consistent with the self-contained artifact
    requirement.
  priority: must
  stability: evolving
- id: specled.spec_review.coverage_pivot_touched_first
  statement: >-
    The Coverage pivot shall list requirements touched by the change set
    (added or modified, or whose covering verification changed) first,
    annotated with their change chips, and shall fold untouched
    requirements behind a disclosure that states their strength is
    unchanged from base.
  priority: should
  stability: evolving
- id: specled.spec_review.misc_panel
  statement: Files that change in the diff but do not map to any spec subject shall be surfaced in a clearly-labeled "outside the spec system" panel as a flat file diff, rather than excluded from the artifact.
  priority: must
  stability: evolving
- id: specled.spec_review.same_artifact_local_and_ci
  statement: mix spec.review shall produce the same HTML artifact locally and in CI, sourced from the same code path with no local-only or CI-only rendering modes.
  priority: must
  stability: evolving
- id: specled.spec_review.diff_against_base
  statement: mix spec.review shall accept an explicit --base ref and otherwise default to the same base detection used by mix spec.next (origin/main, main, master, HEAD).
  priority: must
  stability: evolving
- id: specled.spec_review.read_only_viewer
  statement: The HTML artifact shall be a read-only viewer in v1 with no acceptance state, no per-subject sign-off, and no reviewer-attributed approval recorded by the artifact itself.
  priority: must
  stability: evolving
- id: specled.spec_review.gh_pages_distribution
  statement: A documented GitHub Actions workflow shall be provided that runs mix spec.review on PR open and synchronize, deploys the rendered HTML to a per-PR path on a GitHub Pages branch, and posts or updates a PR comment containing the link.
  priority: should
  stability: evolving
- id: specled.spec_review.triangle_code_classification
  statement: The HTML artifact's sync diagram and sync checklist shall classify findings using the triangle vocabulary documented in docs/concepts.md. Specifically, findings carrying realization-side codes (`branch_guard_realization_drift`, `branch_guard_dangling_binding`) shall flip the SPEC ↔ CODE leg; findings carrying coverage-claim codes (`branch_guard_untested_realization`, `requirement_without_test_tag`, `branch_guard_requirement_without_test_tag`) shall flip the SPEC ↔ TESTS leg; findings carrying observed-coverage codes (`branch_guard_untethered_test`, `branch_guard_underspecified_realization`) shall flip the CODE ↔ TESTS leg; within-spec consistency findings (`overlap/duplicate_covers`, `overlap/must_stem_collision`) shall flip the "spec files are well-formed" checklist row; and `append_only/*` findings shall flip a dedicated "Decisions / governance" checklist row.
  priority: must
  stability: evolving
- id: specled.spec_review.degraded_leg_state
  statement: >-
    The sync diagram shall render a fourth per-leg state — `:degraded` —
    distinct from `:ok`, `:fail`, and `:vacuous`, used when a leg carries a
    `detector_unavailable` finding rather than a positive or negative
    verification. A degraded leg shall render with a `?` glyph (not `✓`)
    and a non-green, non-warning color, and the leg's tooltip shall
    enumerate the distinct `detector_unavailable` reasons
    (`debug_info_stripped`, `umbrella_unsupported`, `no_coverage_artifact`,
    etc.) attributed to that leg. When any leg is degraded, the Spec health
    pane's headline and the Spec health queue entry's badge shall advertise
    that verification is partial; degraded repo state shall not flip the
    change-scoped verdict chip. A `:fail` finding on the same leg
    supersedes `:degraded`; `:degraded` supersedes `:vacuous` and `:ok`.
  priority: must
  stability: evolving
- id: specled.spec_review.decisions_governance_inline
  statement: The Decisions Changed section of the HTML artifact shall render `append_only/*` findings inline next to the ADR they should have authorized (matched by ADR id when the finding's `entity_id` resolves to a changed ADR), and shall surface findings that name no resolvable ADR — including unauthorized requirement deletions, modal downgrades, scenario regressions, and decision deletions — in a dedicated "Governance violations" subsection of the same panel. Each rendered finding shall preserve the code-fenced `fix:` block emitted by `SpecLedEx.AppendOnly.analyze` so reviewers see the remediation contract verbatim.
  priority: must
  stability: evolving
- id: specled.spec_review.coverage_tab_bind_closure
  statement: |
    Each subject's Coverage pivot shall render, per requirement, a one-line bind-closure
    summary of the form "Closure: N MFAs. Reached: M (by tests T1, T2). Unreached: K." —
    where N is the size of the requirement's realization closure (the same closure the
    implementation tier hashes), and Reached plus the test list are computed from the
    `.spec/_coverage/per_test.coverdata` per-test artifact via
    `SpecLedEx.CoverageTriangulation`. When the per-test coverage artifact is missing
    the pivot shall render a single "Coverage artifact unavailable" banner in place of
    the per-row summaries; when the compiler tracer manifest is missing the pivot shall
    render a single "Binding closure unavailable" banner. Both degraded states piggyback
    the page-level `:degraded` leg state machinery rather than rendering empty closure
    rows that would be misread as the absence of test coverage.
  priority: must
  stability: evolving
- id: specled.spec_review.no_realized_by_degrades_spec_to_code
  statement: >-
    When an affected subject declares no `realized_by` bindings — the
    subject-level meta `realized_by` is absent or empty AND no
    requirement on that subject declares its own `realized_by` — the
    view-model build shall synthesize a single `detector_unavailable`
    finding per such subject with reason `no_realized_by` and severity
    `info`, attribute it to that subject, and route it through the
    `detector_unavailable_by_leg` aggregation under the SPEC ↔ CODE leg
    so the sync diagram renders that leg as `:degraded` (per
    `specled.spec_review.degraded_leg_state`) and the partial-report
    surfaces enumerate `no_realized_by` as a distinct reason. A subject
    that declares any non-empty tier in its subject-level or
    requirement-level `realized_by` shall not produce this synthetic
    finding.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: specled.spec_review.clean_pr_collapses
  given:
    - a PR whose change set introduces zero findings
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the top-bar verdict chip renders a clean confirmation
    - the Overview headline states that the change introduces no findings
    - no severity counts are surfaced on the Overview pane
  covers:
    - specled.spec_review.triage_panel
- id: specled.spec_review.finding_renders_top_and_inline
  given:
    - a PR whose change set produces a triangulation finding affecting subject S
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the findings digest lists the finding with its severity
    - subject S's queue row and detail pane carry an inline badge for the finding
  covers:
    - specled.spec_review.inline_finding_badges
- id: specled.spec_review.queue_selects_subject_detail
  given:
    - a PR affecting subjects S1 and S2
  when:
    - the reviewer selects S2's row in the review queue
  then:
    - exactly one detail pane is visible and it renders S2
    - S2's queue row is marked as the current selection
    - the URL fragment identifies S2 so the view is deep-linkable
  covers:
    - specled.spec_review.review_queue_navigation
- id: specled.spec_review.overview_excludes_repo_state
  given:
    - a change set touching 3 subjects in a repo with hundreds of requirements and bindings
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the Overview pane shows change-scoped counts (subjects touched, spec edits, decisions, unmapped files)
    - the Overview pane renders neither the whole-repo requirement/binding/strength inventories nor the sync triangle
    - those inventories and the triangle render on the Spec health pane under a heading naming the head ref as repo state
  covers:
    - specled.spec_review.change_scoped_overview
    - specled.spec_review.repo_state_health_pane
- id: specled.spec_review.findings_delta_classifies
  given:
    - the base ref's committed .spec/state.json records finding F1
    - verification at head produces findings F1 and F2
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the Overview findings delta shows 1 introduced (F2) and 1 pre-existing (F1)
    - the verdict chip reflects only the introduced finding
  covers:
    - specled.spec_review.findings_delta
- id: specled.spec_review.findings_delta_missing_base
  given:
    - the base ref has no committed .spec/state.json
    - verification at head produces findings
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the findings presentation is non-differential and explicitly labeled as lacking base attribution
    - no finding is presented as introduced by the change
  covers:
    - specled.spec_review.findings_delta
- id: specled.spec_review.duplicate_findings_dedup
  given:
    - a change set producing 23 findings that share code detector_unavailable and reason no_realized_by across 23 subjects
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the findings digest renders a single row for the (code, reason) pair with an occurrence count of 23
    - expanding the row lists the 23 affected subjects as links to their queue entries
  covers:
    - specled.spec_review.findings_digest_dedup
- id: specled.spec_review.theme_defaults_and_override
  given:
    - a viewer whose OS reports prefers-color-scheme dark and no stored theme preference
  when:
    - the artifact is opened, the viewer selects Light in the theme toggle, and the page is reloaded
  then:
    - the initial render uses the dark token set
    - after the selection the render uses the light token set
    - after reload the render still uses the light token set despite the OS preference
  covers:
    - specled.spec_review.theme_tokens
- id: specled.spec_review.coverage_pivot_leads_with_touched
  given:
    - a PR that adds requirement R1 to subject S and leaves S's other requirements untouched
  when:
    - the reviewer opens subject S's Coverage pivot
  then:
    - R1 renders first with its ADDED change chip and strength
    - the untouched requirements are folded behind a disclosure stating their strength is unchanged from base
  covers:
    - specled.spec_review.coverage_pivot_touched_first
- id: specled.spec_review.unmapped_change_in_misc_panel
  given:
    - a PR that changes a file with no spec subject mapping (e.g., a dependency bump)
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the file appears in the "outside the spec system" misc panel
    - the misc panel renders the change as a flat file diff
    - the file is not silently excluded from the artifact
  covers:
    - specled.spec_review.misc_panel
- id: specled.spec_review.self_contained_html
  given:
    - a rendered spec.review HTML artifact
  when:
    - the file is opened in a browser with no network connectivity
  then:
    - all CSS, JavaScript, and structural content render correctly
    - the artifact does not request any external network resources
  covers:
    - specled.spec_review.html_artifact
- id: specled.spec_review.subject_card_prose_headline
  given:
    - a PR that affects subject S whose statement field is "S protects credentials at the boundary"
  when:
    - mix spec.review renders the HTML artifact
  then:
    - subject S's detail headline is the prose statement, not the YAML id or file path
    - the YAML id is available as supporting metadata, not the primary headline
  covers:
    - specled.spec_review.spec_first_navigation
- id: specled.spec_review.code_tab_grouped_by_binding
  given:
    - a PR whose code changes touch MFAs in both the api_boundary and implementation tiers of subject S
  when:
    - the reviewer opens subject S's Code pivot in the rendered HTML artifact
  then:
    - the changes are grouped under their realized_by tier headers
    - file paths appear under each tier rather than as the primary organization
  covers:
    - specled.spec_review.per_subject_tabs
- id: specled.spec_review.degraded_leg_renders_with_question_mark
  given:
    - a change set that produces a `detector_unavailable` finding with reason `:no_coverage_artifact`
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the CODE ↔ TESTS evidence leg on the Spec health pane renders with a `?` glyph rather than `✓` or `✗`
    - the leg's tooltip names the `no_coverage_artifact` reason
    - the Spec health pane headline and its queue badge advertise that verification is partial
    - the change-scoped verdict chip is not flipped by the degraded state
  covers:
    - specled.spec_review.degraded_leg_state
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/review_test.exs test/mix/tasks/spec_review_task_test.exs
  execute: true
  covers:
    - specled.spec_review.html_artifact
    - specled.spec_review.spec_first_navigation
    - specled.spec_review.per_subject_tabs
    - specled.spec_review.triage_panel
    - specled.spec_review.inline_finding_badges
    - specled.spec_review.misc_panel
    - specled.spec_review.same_artifact_local_and_ci
    - specled.spec_review.diff_against_base
    - specled.spec_review.read_only_viewer
- kind: command
  target: mix test test/specled_ex/review/html_test.exs
  execute: true
  covers:
    - specled.spec_review.triangle_code_classification
    - specled.spec_review.degraded_leg_state
    - specled.spec_review.decisions_governance_inline
    - specled.spec_review.coverage_tab_bind_closure
- kind: command
  target: mix test test/specled_ex/review/html_layout_test.exs
  execute: false
  covers:
    - specled.spec_review.review_queue_navigation
    - specled.spec_review.change_scoped_overview
    - specled.spec_review.repo_state_health_pane
    - specled.spec_review.findings_digest_dedup
    - specled.spec_review.theme_tokens
    - specled.spec_review.coverage_pivot_touched_first
- kind: command
  target: mix test test/specled_ex/review/findings_delta_test.exs
  execute: false
  covers:
    - specled.spec_review.findings_delta
- kind: command
  target: mix test test/specled_ex/coverage_triangulation_test.exs
  execute: true
  covers:
    - specled.spec_review.coverage_tab_bind_closure
- kind: command
  target: mix test test/specled_ex/review_test.exs
  execute: true
  covers:
    - specled.spec_review.no_realized_by_degrades_spec_to_code
- kind: source_file
  target: lib/mix/tasks/spec.review.ex
  covers:
    - specled.spec_review.diff_against_base
    - specled.spec_review.same_artifact_local_and_ci
- kind: source_file
  target: lib/specled_ex/review.ex
  covers:
    - specled.spec_review.spec_first_navigation
    - specled.spec_review.misc_panel
    - specled.spec_review.no_realized_by_degrades_spec_to_code
    - specled.spec_review.findings_delta
- kind: source_file
  target: lib/specled_ex/review/html.ex
  covers:
    - specled.spec_review.html_artifact
    - specled.spec_review.per_subject_tabs
    - specled.spec_review.triage_panel
    - specled.spec_review.inline_finding_badges
    - specled.spec_review.read_only_viewer
    - specled.spec_review.triangle_code_classification
    - specled.spec_review.degraded_leg_state
    - specled.spec_review.decisions_governance_inline
    - specled.spec_review.coverage_tab_bind_closure
    - specled.spec_review.review_queue_navigation
    - specled.spec_review.change_scoped_overview
    - specled.spec_review.repo_state_health_pane
    - specled.spec_review.findings_digest_dedup
    - specled.spec_review.theme_tokens
    - specled.spec_review.coverage_pivot_touched_first
- kind: source_file
  target: lib/specled_ex/review/coverage_closure.ex
  covers:
    - specled.spec_review.coverage_tab_bind_closure
- kind: source_file
  target: lib/specled_ex/coverage_triangulation.ex
  covers:
    - specled.spec_review.coverage_tab_bind_closure
- kind: workflow_file
  target: priv/spec_init/workflows/spec_review.yml.eex
  covers:
    - specled.spec_review.gh_pages_distribution
```
