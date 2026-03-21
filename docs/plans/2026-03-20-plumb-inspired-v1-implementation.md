# Plumb-Inspired V1 Implementation Plan

Date: 2026-03-20

## Purpose

Record the agreed small V1 implementation plan in source control before making changes across the public docs site and the Elixir helper package.

This document lives in `specled_ex` because the workspace-level `research/` notes are not in a git repository.

## Summary

This V1 adds a guided reconciliation layer to Spec Led Development without changing the authored truth model.

The release should:

- keep `.spec` as the authored source of truth
- add one new beginner-facing command: `mix spec.assist`
- improve guidance from the existing `spec.diffcheck` and `spec.report` commands
- update `specled_ex` docs, templates, and skill text to teach one simple loop
- update `specleddev` docs pages so the public explanation matches the package behavior

This V1 should remain:

- deterministic
- human approved
- brownfield friendly
- useful for bug fixes and regression-test-driven work

## Product Boundaries

### Included In V1

- `mix spec.assist`
- richer `mix spec.diffcheck` guidance output
- richer `mix spec.report` frontier reporting
- package-facing doc updates in `specled_ex`
- public doc updates in `specleddev`
- tests for the new guidance layer and command behavior

### Explicitly Deferred

- file-writing scaffolds
- `mix spec.status`
- repo mode configuration and policy files
- LLM drafting
- chat log mining
- auto-updating specs from inferred decisions
- beadwork integration

## Default User Loop To Teach

This is the only beginner-facing loop the docs and package should teach in V1:

1. make the change
2. add or tighten the test if behavior changed
3. run `mix spec.assist`
4. update the right subject or ADR if needed
5. run `mix spec.check`

This should appear consistently in:

- `specled_ex/README.md`
- local workspace templates from `mix spec.init`
- `specled_ex` skill text
- public docs pages in `specleddev`

## Workstream 1: `specled_ex` Package Changes

### 1. Add `mix spec.assist`

Add a new Mix task:

- path: `lib/mix/tasks/spec.assist.ex`
- purpose: provide read-only, deterministic guidance after a change
- allowed inputs:
  - current repo diff
  - `--base <ref>` for diff comparison
  - `--bugfix` for bug-fix triage language

Behavior:

- inspect changed files
- map changed files to known subject ids using existing coverage logic
- classify the change as one of:
  - local covered change
  - cross-cutting covered change
  - uncovered frontier change
  - likely non-contract change
- print:
  - changed files
  - impacted subject ids
  - why the change got its classification
  - the recommended next step
  - the exact command or edit expected next

The task should be read-only in V1 and always exit `0` unless argument parsing fails.

### 2. Extract Or Reuse Shared Change Analysis

Create or refactor a small internal analysis layer so these commands do not duplicate logic:

- `mix spec.diffcheck`
- `mix spec.report`
- `mix spec.assist`

The shared layer should expose:

- changed files
- impacted subject ids
- uncovered changed files
- whether the change spans multiple covered subjects

Implementation should prefer existing `Coverage` and `Diffcheck` behavior, not new inference-heavy logic.

### 3. Extend `mix spec.diffcheck`

Keep current failure semantics exactly as they are now.

Add additive output only:

- impacted subject ids
- whether the change appears cross-cutting
- whether changed files sit outside current subject coverage
- recommendation to run `mix spec.assist` when that would help

`spec.diffcheck` stays the enforcement command.
`spec.assist` becomes the guidance command.

### 4. Extend `mix spec.report`

Keep current JSON and human report structure stable, but add a new `frontier` section to JSON output with:

- `covered_subject_count`
- `uncovered_source_files`
- `uncovered_guide_files`
- `uncovered_test_files`
- `uncovered_file_count`

Update human-readable output to include a short “next gaps” summary aimed at maintainers.

Do not introduce clustering or policy modes in V1.

### 5. Bug Fix Triage Rule

When `mix spec.assist --bugfix` is used, the task should apply this rule:

- if an existing requirement already states the intended behavior:
  - recommend keeping or adding the regression test
  - optionally recommend tightening scenario wording
  - do not recommend a new requirement by default
- if intended behavior is missing or ambiguous:
  - recommend refining or adding a requirement
  - recommend a scenario when the regression is best described as an example
- if the fix changes durable behavior across multiple subjects:
  - recommend ADR review

This rule should also shape the docs and examples.

## Workstream 2: `specled_ex` Docs, Templates, And Skill

Update these package-facing surfaces:

- `README.md`
- `skills/write-spec-led-specs/SKILL.md`
- `priv/spec_init/README.md.eex`
- `priv/spec_init/AGENTS.md.eex`

Changes:

- teach `mix spec.assist` as the first post-change step
- reduce emphasis on command catalogs for beginners
- present the default loop clearly
- add explicit greenfield, brownfield, and bug-fix guidance
- keep ADR guidance strict: ADRs remain durable and rare

The templates should teach one simple flow, not several competing ones.

## Workstream 3: `specleddev` Public Docs Updates

Update these public pages:

- `getting-started.mdx`
- `tooling.mdx`
- `how-it-works.mdx`
- `use-cases/bug-fix.mdx`
- `use-cases/brownfield.mdx`

Expected content changes:

- explain the new “change -> assist -> authored update -> strict check” loop
- make bug-fix guidance more practical for regression-test-first work
- make brownfield adoption less intimidating
- explain that the method is still lightweight and deterministic

Historical framing to include:

- Fred Brooks: conceptual integrity still matters
- Martin Fowler: keep the loop lightweight and evolutionary

The public framing should be:

Spec Led Development is building on proven software engineering lessons, not replacing them.

## Expected File Touches

### `specled_ex`

Likely files:

- `lib/mix/tasks/spec.diffcheck.ex`
- `lib/mix/tasks/spec.report.ex`
- `lib/mix/tasks/spec.assist.ex`
- one new internal analysis module under `lib/specled_ex/`
- `README.md`
- `skills/write-spec-led-specs/SKILL.md`
- `priv/spec_init/README.md.eex`
- `priv/spec_init/AGENTS.md.eex`
- new tests under `test/specled_ex/`

### `specleddev`

Likely files:

- `getting-started.mdx`
- `tooling.mdx`
- `how-it-works.mdx`
- `use-cases/bug-fix.mdx`
- `use-cases/brownfield.mdx`

## Test Plan

Add package tests for:

- single-subject covered change guidance
- multi-subject covered change guidance
- uncovered frontier change guidance
- `--bugfix` when current requirement already covers the intended behavior
- `--bugfix` when the intended behavior is missing from the current subject
- additive `spec.diffcheck` output without changed failure semantics
- additive `spec.report --json` output with the new `frontier` section

Validation passes after implementation:

- `mix test` in `specled_ex`
- manual validation against `jido_action` as the brownfield proving repo
- docs pass local preview/build checks in `specleddev`

## Acceptance Criteria

The V1 is complete when:

- a new user can learn one simple loop from the package docs and public docs
- `mix spec.assist` gives useful next-step guidance without writing files
- `spec.diffcheck` still enforces drift but now points users toward the right follow-up
- `spec.report` makes the uncovered frontier easier to see in brownfield repos
- bug-fix guidance does not push users toward unnecessary new requirements
- the docs site and package docs teach the same workflow

## Commit Plan

Recommended commit sequence:

1. commit this plan document in `specled_ex`
2. commit `specled_ex` code, tests, package docs, skill, and templates together
3. commit `specleddev` public docs updates separately

This keeps the planning artifact committed first and keeps package changes separate from site messaging changes.

## Assumptions

- V1 should stay small and should not try to deliver the full roadmap
- `mix spec.assist` is the only new beginner-facing command in this slice
- tests remain evidence, not peer truth with specs
- the authored `.spec` layer stays deterministic and human approved
- brownfield friendliness matters as much as greenfield clarity
