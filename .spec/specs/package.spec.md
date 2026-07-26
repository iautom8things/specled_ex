# specled_ex

Local tooling package for Spec Led Development repositories.

## Intent

Provide Mix tasks and library functions that let Elixir projects
adopt Spec Led Development with a single dependency.

Shipped scaffold templates (README, local skill) advise the ADR-or-trailer
fork wherever they describe the ADR obligation, so generated workspaces
inherit the two-armed guidance.

As of 0.3.1 the package guarantees a stable committed realization baseline
for bare-module `api_boundary` entries: adopting repos no longer see
`.spec/realization_hashes.json` churn (drop-and-reseed oscillation) across
consecutive clean `mix spec.check` runs.

`mix.exs` is bound here as a whole-file surface member (package scaffolding,
deps, and Mix task wiring). An edit to an unrelated top-level key — e.g.
`test_coverage: [summary: [threshold: ...]]`, tuned as an internal CI-gate
exception — legitimately touches this subject's tracked surface without
reflecting any change to what this subject verifies.

The package docs and bootstrap skill teach the same `mix spec.check` verdict
read protocol as the live `spec.prime` and `spec.next` guidance, while avoiding
placing that protocol on commands that do not emit a `spec.check result=` line.

The bootstrap skill's reference pages state config-severity defaults as the
code resolves them (`SpecLedEx.BranchCheck` per-code defaults and its
`Trailer` preset mapping), describe dropped severity overrides as `[CONFIG]`
stderr diagnostics rather than silent no-ops, and distinguish templates
`mix spec.init` scaffolds from templates merely shipped under
`priv/spec_init/` (the spec_review workflow is shipped, not scaffolded).

```yaml spec-meta
id: specled.package
kind: package
status: active
summary: Elixir package for Spec Led Development. Provides Mix tasks to scaffold, orient, index, guide, validate, summarize, and strictly check authored specs. Docs include coverage capture (docs/coverage.md), including the per-test boundary-hook wiring subsection and Stage-2 auditor/unhooked-degrade claim (exact within disclosed chained windows).
surface:
  - README.md
  - CHANGELOG.md
  - docs/adoption.md
  - docs/concepts.md
  - docs/coverage.md
  - skills/spec-led-bootstrap/SKILL.md
  - skills/spec-led-bootstrap/references/*.md
  - priv/spec_init/README.md.eex
  - priv/spec_init/AGENTS.md.eex
  - priv/spec_init/decisions/README.md.eex
  - priv/spec_init/agents/skills/spec-led-development/SKILL.md.eex
  - priv/spec_init/specs/spec_system.spec.md.eex
  - priv/spec_init/workflows/spec_review.yml.eex
  - mix.exs
  - lib/specled_ex.ex
  - test/test_helper.exs
realized_by:
  api_boundary:
    - "SpecLedEx.build_index/2"
    - "SpecLedEx.verify/3"
    - "SpecLedEx.report/3"
    - "SpecLedEx.write_state/4"
    - "SpecLedEx.normalize_for_state/1"
    - "SpecLedEx.detect_spec_dir/1"
    - "SpecLedEx.detect_authored_dir/2"
    - "SpecLedEx.detect_decision_dir/2"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.local_skill_scaffold
  - specled.decision.explicit_subject_ownership
  - specled.decision.guided_reconciliation_loop
```

## Requirements

```yaml spec-requirements
- id: specled.package.mix_tasks
  statement: The package shall provide mix spec.init, mix spec.prime, mix spec.next, mix spec.check, mix spec.status, mix spec.decision.new, mix spec.index, mix spec.validate, and mix spec.review as user-facing commands.
  priority: must
  stability: stable
- id: specled.package.default_local_loop
  statement: The package README shall teach mix spec.prime as the session-start context command, a default local loop centered on mix spec.next and mix spec.check that includes a step to annotate new tests with `@tag spec:` when test-tag scanning is enabled, explain the ready-for-check decision, reserve ADRs for durable cross-cutting policy, and present mix spec.status as occasional plus mix spec.index and mix spec.validate as advanced plumbing.
  priority: should
  stability: evolving
- id: specled.package.test_tag_annotation_docs
  statement: The package README shall document the supported ExUnit test-tag annotation shapes for scanner-backed verification, including scalar and list-valued `@tag spec`, `@moduletag spec`, and `@describetag spec`.
  priority: should
  stability: evolving
- id: specled.package.index_and_state
  statement: The package shall index authored subject specs, index durable ADRs, and write derived state to .spec/state.json.
  priority: must
  stability: stable
- id: specled.package.declarative_governance
  statement: The package shall keep `.spec` declarative and current-state only, using ADRs for durable cross-cutting policy and Git history for change over time.
  priority: must
  stability: stable
- id: specled.package.adoption_guide
  statement: The package shall provide an adoption guide at `docs/adoption.md` that walks both the greenfield path (starting from `mix new`) and the brownfield path (bolting onto an existing tree), that names the severity-graduation step where `branch_guard` and `guardrails` codes move from `:warning` to `:error`, that splits coverage triangulation into Phase 4a (aggregate, zero wiring) and Phase 4b (per-test attribution, opt-in boundary wiring), and that teaches the `mix spec.check` verdict read protocol.
  priority: must
  stability: evolving
- id: specled.package.concepts_guide
  statement: The package shall provide a concepts document at `docs/concepts.md` that explains the spec triangle (specs ↔ code ↔ tests), the `realized_by` tiers, the graceful-degrade rule that emits `detector_unavailable` instead of failing when a detector's prerequisites are missing, how to accept intentional realization drift (the durable `mix spec.check --accept-drift` path, the PR-scoped `Spec-Drift:` trailer, and the implementation-tier delete-and-reseed ritual), and the `mix spec.check` verdict read protocol.
  priority: must
  stability: evolving
- id: specled.package.doc_identifier_integrity
  statement: Documentation, skill files, and the repo-resident spec workspace (`.spec/**`) shall reference only finding codes defined by the implementation. This is mechanically enforced for the five code families guarded today — `append_only/*`, `overlap/*`, `evidence/*`, `cross_field/*`, and `branch_guard_*` — whose shared namespace or prefix distinguishes a finding code from ordinary prose; every other emitted code is a bare snake_case identifier (`detector_unavailable`, `spec_requirement_too_short`, and the validator and tag-scanner codes among them), and four such stem patterns — `detector_`, `decision_`, `verification_`, `requirement_` — each produce false positives against the current corpus, where the same stems name requirement ids, config keys, and output fields, so the codes they would match remain author-enforced; a few narrower stems (`surface_target_`, `scenario_cover_`) collide with nothing today and are candidates for later widening rather than cases the technique cannot reach. A decision record may name an unimplemented (budgeted or rejected) code only when the reference carries an explicit `spec-lint:allow-code=<token>` marker on the same line, and user-facing docs and skill files shall show config severity values in the bare YAML token form.
  priority: must
  stability: stable
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.package.index_and_state
    - specled.package.declarative_governance
    - specled.package.doc_identifier_integrity
- kind: readme_file
  target: README.md
  covers:
    - specled.package.default_local_loop
    - specled.package.test_tag_annotation_docs
- kind: command
  target: >-
    mix run -e 'Mix.Task.load_all(); Enum.each(~w(spec.init spec.prime spec.next spec.check spec.status spec.decision.new spec.index spec.validate spec.review), fn task -> Mix.Task.get(task) || raise("missing #{task}") end)'
  execute: true
  covers:
    - specled.package.mix_tasks
- kind: command
  target: >-
    sh -c 'grep -Fq "## Greenfield" docs/adoption.md &&
    grep -Fq "## Brownfield" docs/adoption.md &&
    grep -Fq "Same as greenfield step 6: graduate" docs/adoption.md &&
    grep -Fq "enforcement: error" docs/adoption.md &&
    grep -Fq "guardrails:" docs/adoption.md &&
    grep -Fq "branch_guard:" docs/adoption.md &&
    grep -Fq "### Phase 4a — Aggregate coverage (zero wiring)" docs/adoption.md &&
    grep -Fq "### Phase 4b — Per-test attribution (opt-in)" docs/adoption.md &&
    grep -Fq "setup {SpecLedEx.Coverage, :per_test_boundary}" docs/adoption.md'
  execute: true
  covers:
    - specled.package.adoption_guide
- kind: source_file
  target: docs/concepts.md
  covers:
    - specled.package.concepts_guide
```
