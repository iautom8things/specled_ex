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
  - lib/specled_ex/review/coverage_closure.ex
  - lib/specled_ex/review/file_diff.ex
  - lib/specled_ex/review/findings_delta.ex
  - lib/specled_ex/review/html.ex
  - lib/specled_ex/review/spec_diff.ex
  - priv/spec_review_assets/*
  - priv/spec_init/workflows/spec_review.yml.eex
  - test/specled_ex/review_test.exs
  - test/specled_ex/review/coverage_closure_test.exs
  - test/specled_ex/review/html_test.exs
  - test/mix/tasks/spec_review_task_test.exs
decisions:
  - specled.decision.spec_review_html_viewer
  - specled.decision.spec_review_change_scoped_master_detail
  - specled.decision.evidence_orphan_branch_split
  - specled.decision.aggregate_first_spec_coverage
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
    file breakdown, and changed decisions. Each spec-edit entry shall
    deep-link to that subject's Spec pivot (activating the Spec tab on
    arrival), not merely to the subject's pane with its default pivot.
    Whole-repo inventories (requirement, binding, and verification counts;
    coverage strength totals) and whole-repo verification state (the
    triangle diagram and its per-leg checks) shall not render on the
    Overview pane.
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
    finding set from the evidence-store entry keyed by the base ref's tree
    (`git rev-parse <base>^{tree}`). The stored base findings list is
    authoritative instead of a finding set recomputed with the current parser. The
    change verdict shall be driven by introduced findings only. A finding
    whose producer `mix spec.check` never runs as part of recording base
    evidence — for example the review-only `no_realized_by`
    `detector_unavailable` finding described in
    `specled.spec_review.no_realized_by_degrades_spec_to_code`, which is
    synthesized only inside the review artifact's own view-model build —
    has no comparable base-side attestation and shall always classify as
    pre-existing, never introduced and never resolved, regardless of
    whether it is present at head.
  priority: must
  stability: evolving
- id: specled.spec_review.findings_delta_base_fallback
  statement: >-
    When the base tree cannot be resolved or its evidence entry is absent the Overview pane
    shall fall back to a non-differential findings presentation that is
    explicitly labeled as lacking base attribution — findings shall never
    be silently presented as introduced by the change when base attribution
    is unavailable. Its verdict shall be indeterminate (`clean?: nil`), and
    the presentation shall name `mix spec.sync` or a check run on the base
    content as the healing path.
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
    added/modified/removed counts across both requirements and scenarios
    for Spec, so a removal-only spec edit never labels itself unchanged;
    touched-requirement count for Coverage; reference count for Decisions).
    Modified-requirement wording shall diff inline (del/ins) for surgical
    edits, coalescing one-word unchanged bridges, and shall fall back to
    the full old statement stacked above the full new statement when the
    wording mostly changed. The default-selected pivot shall be the one
    carrying this change set's edits (Code when code changed; Spec when
    only the spec changed), and pivots with no content shall render
    visibly de-emphasized with the reason available.
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
    feel clean. This includes findings that have no comparable base-side
    attestation (see `specled.spec_review.findings_delta`): such a finding
    is pre-existing by definition and shall never by itself make an
    otherwise-clean change verdict read as not-clean.
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
  statement: >-
    mix spec.review shall accept an explicit --base ref and otherwise
    default to the same base detection used by mix spec.next (origin/main,
    main, master, HEAD). Files deleted between base and head shall render
    as full-deletion diffs and count toward the artifact's file and line
    stats — never silently dropped. Full-file deletions and oversized
    diffs shall render collapsed by default with a summary note (file
    deleted / large diff, with the line count) instead of auto-expanding.
    The header diffstat shall expose an info affordance explaining that
    tool-managed spec state files are intentionally excluded from the
    counts, which may differ from the hosting forge's numbers.
  priority: must
  stability: evolving
- id: specled.spec_review.read_only_viewer
  statement: The HTML artifact shall be a read-only viewer in v1 with no acceptance state, no per-subject sign-off, and no reviewer-attributed approval recorded by the artifact itself.
  priority: must
  stability: evolving
- id: specled.spec_review.binary_content_safe
  statement: The renderer shall tolerate non-UTF-8 content anywhere in the change set. Untracked files whose content is not valid UTF-8 shall render as a placeholder line naming the file as binary with its byte size, never inlining raw bytes; unified diff output obtained from git shall be sanitized to valid UTF-8 (invalid sequences replaced) before parsing. mix spec.review shall complete and produce a valid artifact for such change sets rather than raising.
  priority: must
  stability: evolving
- id: specled.spec_review.gh_pages_distribution
  statement: A documented GitHub Actions workflow shall be provided that runs mix spec.review on PR open and synchronize, deploys the rendered HTML to a per-PR path on a GitHub Pages branch, and posts or updates a PR comment containing the link.
  priority: should
  stability: evolving
- id: specled.spec_review.gh_pages_privilege_separation
  statement: >-
    The provided GitHub Actions workflow shall separate the job that executes
    untrusted pull-request code — running mix spec.review to render the HTML
    from the PR head — from the job that holds write-scoped tokens
    (`contents: write` / `pull-requests: write`) to push the GitHub Pages
    branch and post the PR comment, handing the rendered HTML between them as
    a workflow artifact so that no single job both runs pull-request-provided
    code and holds a write-scoped token. The workflow's top-level permissions
    shall default to read-only, and the write-scoped job shall not check out
    or execute pull-request-provided code.
  priority: must
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
    that verification is partial; the change-scoped verdict chip shall
    remain driven by the change set alone, independent of degraded repo
    state. A `:fail` finding on the same leg supersedes `:degraded`;
    `:degraded` supersedes `:vacuous` and `:ok`.
  priority: must
  stability: evolving
- id: specled.spec_review.decisions_governance_inline
  statement: The Decisions Changed section of the HTML artifact shall render `append_only/*` findings inline next to the ADR they should have authorized (matched by ADR id when the finding's `entity_id` resolves to a changed ADR), and shall surface findings that name no resolvable ADR — including unauthorized requirement deletions, modal downgrades, scenario regressions, and decision deletions — in a dedicated "Governance violations" subsection of the same panel. Each rendered finding shall preserve the code-fenced `fix:` block emitted by `SpecLedEx.AppendOnly.analyze` so reviewers see the remediation contract verbatim. A decision file deleted in the change set shall render as a REMOVED card carrying its base-ref parsed content (title, status, affects, body), never as an unexplained "no parsed ADR" stub. A modified ADR shall render a section-level body diff against its base-ref body — added/removed sections chipped, edited sections showing inline wording del/ins — rather than only the head document. Obsidian-style `[[id]]` references in ADR prose shall resolve to in-page links to the referenced ADR's card (outside code spans), degrading to a plain code ref when the target is not rendered on the page.
  priority: must
  stability: evolving
- id: specled.spec_review.coverage_tab_bind_closure
  statement: |
    Each subject's Coverage pivot shall render, per requirement, a one-line bind-closure
    summary sourced from `SpecLedEx.Review.CoverageClosure.build_v2/2`'s v2-envelope
    reach data, of the form "Closure: N MFAs — K executed (X.X%). Self-verified:
    yes/no. Tagged tests: T1 (executed), T2 (linked)." — where N is
    `closure_mfa_count`, K is the count of `covered_mfas`, X.X% is
    `closure_coverage_pct`, "Self-verified" reflects `self_verified?`, and the tagged
    tests list every `tagged_tests` entry with its evidence `:strength` ("claimed" /
    "linked" / "executed"). A "Reached by tests" row naming every `"executed"`-
    strength tagged test shall render exclusively when the subject's coverage mode
    is `:per_test` (`:ok_per_test`) — aggregate coverage has no per-test attribution
    to name, so the row stays absent there. `"executed"` strength and the per_test
    `closure_coverage_pct` both reflect the `--per-test` engine's observed
    attribution, which is race-bounded (an ExUnit `test_finished` cast-timing race
    can bleed coverage between adjacent tests regardless of the `degraded` flag;
    see `specled_-cpw` and `specled.decision.aggregate_first_spec_coverage`) rather
    than exact — the closure line and the "Reached by tests" row shall each be
    discoverably qualified as observed/approximate, never asserted as exact
    per-test isolation. Because `:ok_per_test`'s per-requirement MFA coverage is
    still computed via a file-level proxy rather than the per-test engine's real
    MFA-level data, the per_test closure line shall additionally carry a qualifier
    noting the coverage percentage is approximate. Each subject card shall
    additionally carry a rollup badge summarizing the subject's coverage status (a
    self-verified/total count and mode when coverage data loaded, or a muted
    "coverage unavailable" chip when degraded). The v2 envelope's own `generated_at`
    timestamp shall render in the Coverage tab with an elapsed-time note, flagged as
    possibly stale past a fixed age threshold. `:no_coverage_artifact`,
    `:legacy_artifact` (naming `mix spec.cover.test` as the re-run command),
    `:invalid_artifact`, and `:async_contaminated` (a degraded `:per_test` envelope)
    shall each render their own distinct honest banner in place of the per-row
    summaries — never collapsing into one another, into a fake 0%, or into an
    empty-but-ok result; a missing compiler tracer manifest (`:no_tracer_manifest`)
    shall render a single "Binding closure unavailable" banner. All degraded states
    piggyback the page-level `:degraded` leg state machinery rather than rendering
    empty closure rows that would be misread as the absence of test coverage.
  priority: must
  stability: evolving
- id: specled.spec_review.coverage_tab_v2_envelope_data_layer
  statement: >-
    `SpecLedEx.Review.CoverageClosure.build_v2/2` shall provide the v2
    envelope-based counterpart to `build/2` — reading
    `SpecLedEx.Coverage.Store.read_v2/1` instead of the v1 record list, and
    returning, per requirement, `closure_coverage_pct`, `covered_mfas` /
    `uncovered_mfas` (via `SpecLedEx.Coverage.MfaKey`), and `tagged_tests`
    with an evidence `:strength` (`"claimed"` / `"linked"` / `"executed"`).
    Subject-level status distinguishes `:ok_aggregate` from `:ok_per_test`
    coverage, and `:no_coverage_artifact` / `:legacy_artifact` /
    `:invalid_artifact` / `:no_tracer_manifest` / `:async_contaminated`
    (a `:per_test` envelope with `degraded: true` — the flag-1 special case
    that keeps a corrupted per-test capture from misreporting as trustworthy
    `:ok_per_test`) degrade distinctly rather than collapsing into one
    empty-but-ok result. `build/2` remains unchanged and still available for
    any caller that needs the v1 shape; `Review.build_view/3` now calls
    `build_v2/2` and the Coverage pivot renders its v2 shape, per
    `coverage_tab_bind_closure`.
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
    finding. Because `mix spec.check` never synthesizes this finding when
    recording base evidence, it has no comparable base-side attestation:
    per `specled.spec_review.findings_delta`, the findings differential
    shall always classify it as pre-existing, never introduced, so a
    subject's static lack of bindings is never misattributed to whichever
    change happens to touch that subject next.
  priority: must
  stability: evolving
- id: specled.spec_review.shared_file_fanin_collapse
  statement: >-
    When a single changed file is the only changed file for three or more
    code-only subjects, the review queue shall replace those subjects'
    individual rows with one shared-file group row inside the code-only
    group, labeled by the file path and carrying the collapsed-subject
    count and an aggregated finding indicator. A code-only subject with
    any other changed file shall retain its individual row; spec-edited
    subjects shall never be collapsed; each changed file meeting the
    threshold shall produce its own group row. Collapsed subjects' unit
    sections shall remain rendered and reachable by URL fragment, and the
    queue filter shall match a group row when the filter text matches any
    collapsed subject's id.
  priority: must
  stability: evolving
- id: specled.spec_review.shared_file_group_pane
  statement: >-
    Selecting a shared-file group row shall render a group detail pane
    that renders the shared file's diff exactly once, alongside one card
    per collapsed subject carrying the subject's id, its prose summary
    clamped to a preview, and that subject's inline finding badges. Each
    card shall link to the subject's full unit section so the reviewer
    can pivot from the shared diff to any subject's Spec / Code /
    Coverage / Decisions detail.
  priority: must
  stability: evolving
- id: specled.spec_review.shared_file_spec_modal
  statement: >-
    Activating a subject card in the shared-file group pane shall open a
    modal dialog rendering that subject's full spec content — the prose
    statement, requirements, and scenarios — sourced from content
    embedded in the artifact with no network fetch, while the group
    pane's diff remains visible behind the modal. The modal shall close
    on Escape and on backdrop click, and shall contain a link to the
    subject's full unit section.
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
    - the evidence entry for the base ref's tree records finding F1
    - verification at head produces findings F1 and F2
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the Overview findings delta shows 1 introduced (F2) and 1 pre-existing (F1)
    - the verdict chip reflects only the introduced finding
  covers:
    - specled.spec_review.findings_delta
- id: specled.spec_review.findings_delta_excludes_synthetic
  given:
    - a subject that has always declared no `realized_by` bindings
    - the evidence entry for the base ref's tree records no findings for that subject
    - the change set touches a file belonging to that subject but does not add any binding
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the synthesized no_realized_by detector_unavailable finding for that subject classifies as pre-existing, not introduced
    - the verdict chip and change verdict read as clean
  covers:
    - specled.spec_review.no_realized_by_degrades_spec_to_code
- id: specled.spec_review.findings_delta_missing_base
  given:
    - the base ref's tree has no evidence entry
    - verification at head produces findings
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the findings presentation is non-differential and explicitly labeled as lacking base attribution
    - no finding is presented as introduced by the change
    - the verdict is indeterminate and names how to fetch or record base evidence
  covers:
    - specled.spec_review.findings_delta_base_fallback
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
- id: specled.spec_review.untracked_binary_placeholder
  given:
    - a change set whose untracked files include a non-UTF-8 binary file (e.g. an ets tab2file dump such as Hex's cache.ets restored into the workspace by CI caching)
  when:
    - mix spec.review renders the HTML artifact
  then:
    - rendering completes without raising UnicodeConversionError
    - the binary file renders as a placeholder line naming it binary with its byte size
    - no raw bytes of the binary file are inlined in the artifact
  covers:
    - specled.spec_review.binary_content_safe
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
- id: specled.spec_review.shared_file_queue_collapses_fanout
  given:
    - a change set where lib/atlas/application.ex is the only changed file for 17 code-only subjects
    - a code-only subject `versioning` whose changed files are lib/atlas/application.ex plus two others
  when:
    - mix spec.review renders the HTML artifact
  then:
    - the code-only queue group renders one shared-file group row labeled lib/atlas/application.ex carrying a count of 17 and an aggregated finding indicator
    - none of the 17 collapsed subjects render an individual queue row
    - subject `versioning` retains its own individual queue row
    - each of the 17 collapsed subjects' unit sections is still reachable via its URL fragment
    - typing a collapsed subject's id into the queue filter surfaces the group row
  covers:
    - specled.spec_review.shared_file_fanin_collapse
- id: specled.spec_review.shared_file_group_pane_renders_once
  given:
    - a rendered artifact whose queue contains a shared-file group row for lib/atlas/application.ex collapsing 17 subjects
  when:
    - the reviewer selects the group row
  then:
    - the detail pane renders the lib/atlas/application.ex diff exactly once
    - the pane renders 17 subject cards, each carrying the subject id, a clamped prose summary, and that subject's finding badges
    - each card links to its subject's full unit section
  covers:
    - specled.spec_review.shared_file_group_pane
- id: specled.spec_review.shared_file_modal_orients_reviewer
  given:
    - an open shared-file group pane containing a card for subject session_process.horde_singleton
  when:
    - the reviewer activates the card
  then:
    - a modal dialog renders the subject's prose statement, requirements, and scenarios from artifact-embedded content with no network request
    - the group pane's diff remains visible behind the modal
    - pressing Escape or clicking the backdrop closes the modal
    - the modal contains a link to the subject's full unit section
  covers:
    - specled.spec_review.shared_file_spec_modal
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
  execute: true
  covers:
    - specled.spec_review.review_queue_navigation
    - specled.spec_review.change_scoped_overview
    - specled.spec_review.repo_state_health_pane
    - specled.spec_review.findings_digest_dedup
    - specled.spec_review.theme_tokens
- kind: command
  target: mix test test/specled_ex/review/html_layout_test.exs
  execute: true
  covers:
    - specled.spec_review.coverage_pivot_touched_first
- kind: command
  target: mix test test/specled_ex/review/findings_delta_test.exs
  execute: true
  covers:
    - specled.spec_review.findings_delta
    - specled.spec_review.findings_delta_base_fallback
- kind: command
  target: mix test test/specled_ex/coverage_triangulation_test.exs
  execute: true
  covers:
    - specled.spec_review.coverage_tab_bind_closure
- kind: command
  target: mix test test/specled_ex/review/coverage_closure_test.exs
  execute: true
  covers:
    - specled.spec_review.coverage_tab_v2_envelope_data_layer
- kind: command
  target: mix test test/specled_ex/review/file_diff_test.exs
  execute: true
  covers:
    - specled.spec_review.binary_content_safe
- kind: command
  target: mix test test/specled_ex/review_test.exs
  execute: true
  covers:
    - specled.spec_review.no_realized_by_degrades_spec_to_code
- kind: command
  target: mix test test/specled_ex/review_test.exs
  execute: true
  covers:
    - specled.spec_review.shared_file_fanin_collapse
- kind: command
  target: mix test test/specled_ex/review/html_layout_test.exs
  execute: true
  covers:
    - specled.spec_review.shared_file_fanin_collapse
    - specled.spec_review.shared_file_group_pane
    - specled.spec_review.shared_file_spec_modal
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
    - specled.spec_review.shared_file_fanin_collapse
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
    - specled.spec_review.shared_file_fanin_collapse
    - specled.spec_review.shared_file_group_pane
    - specled.spec_review.shared_file_spec_modal
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
    - specled.spec_review.gh_pages_privilege_separation
```
