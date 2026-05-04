# Spec Review

A self-contained HTML artifact that turns a Git change set into a spec-aware PR review surface.

## Intent

Render the structured triangulation that specled_ex already produces (spec ↔ binding ↔ test ↔ coverage) as a human review surface, so the rigor that today exists only as a CI gate becomes legible during the act of review. Reviewers see intent first (the spec's prose statement), then pivot to code, tests, coverage, and decisions from the same anchor. Changes that don't map to any subject are surfaced honestly in a labeled "outside the spec system" panel rather than hidden.

The artifact is read-only in v1. Acceptance still happens via the host platform's existing approval flow (e.g., GitHub's Approve button); the artifact's job is to make that approval informed, not to record it.

```spec-meta
id: specled.spec_review
kind: workflow
status: active
summary: Renders a Git change set as a self-contained HTML PR review surface. Spec-first navigation with prose-headlined subject cards, per-subject tabs (Spec / Code / Coverage / Decisions), top triage panel for findings, and a misc panel for unmapped changes. Same artifact runs locally and in CI.
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
```

## Requirements

```spec-requirements
- id: specled.spec_review.html_artifact
  statement: mix spec.review shall produce a self-contained HTML file with all CSS and JavaScript embedded so the artifact renders correctly without any external network resources at view time.
  priority: must
  stability: evolving
- id: specled.spec_review.spec_first_navigation
  statement: The HTML shall organize content by spec subject as the primary unit, with each affected subject rendered as a card whose headline is the subject's human-readable prose statement rather than its raw YAML or file path.
  priority: must
  stability: evolving
- id: specled.spec_review.per_subject_tabs
  statement: Each subject card shall expose four tabs - Spec, Code, Coverage, and Decisions - that pivot from the subject's intent to its supporting artifacts. The Code tab shall organize changes by realized_by binding tier rather than by file path.
  priority: must
  stability: evolving
- id: specled.spec_review.triage_panel
  statement: The HTML shall render a top-of-page triage panel that summarizes findings (count, severity breakdown) and the affected subject count for the change set. The panel shall collapse to a single confirmation row when there are zero findings, so clean change sets feel clean.
  priority: must
  stability: evolving
- id: specled.spec_review.inline_finding_badges
  statement: Findings affecting a subject shall additionally render as inline badges on that subject's card, in addition to appearing in the top-of-page triage panel.
  priority: must
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
```

## Scenarios

```spec-scenarios
- id: specled.spec_review.clean_pr_collapses
  given:
    - a PR whose change set produces zero findings
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the top-of-page triage panel collapses to a single confirmation row
    - no severity counts are surfaced
  covers:
    - specled.spec_review.triage_panel
- id: specled.spec_review.finding_renders_top_and_inline
  given:
    - a PR whose change set produces a triangulation finding affecting subject S
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the top-of-page triage panel lists the finding with its severity
    - subject S's card carries an inline badge for the finding
  covers:
    - specled.spec_review.inline_finding_badges
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
    - subject S's card headline is the prose statement, not the YAML id or file path
    - the YAML id is available as supporting metadata, not the primary headline
  covers:
    - specled.spec_review.spec_first_navigation
- id: specled.spec_review.code_tab_grouped_by_binding
  given:
    - a PR whose code changes touch MFAs in both the api_boundary and implementation tiers of subject S
  when:
    - the reviewer opens subject S's Code tab in the rendered HTML artifact
  then:
    - the changes are grouped under their realized_by tier headers
    - file paths appear under each tier rather than as the primary organization
  covers:
    - specled.spec_review.per_subject_tabs
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
- kind: source_file
  target: lib/specled_ex/review/html.ex
  covers:
    - specled.spec_review.html_artifact
    - specled.spec_review.per_subject_tabs
    - specled.spec_review.triage_panel
    - specled.spec_review.inline_finding_badges
    - specled.spec_review.read_only_viewer
    - specled.spec_review.triangle_code_classification
- kind: workflow_file
  target: priv/spec_init/workflows/spec_review.yml.eex
  covers:
    - specled.spec_review.gh_pages_distribution
```
