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

```yaml spec-meta
id: specled.package
kind: package
status: active
summary: Elixir package for Spec Led Development. Provides Mix tasks to scaffold, orient, index, guide, validate, summarize, and strictly check authored specs.
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
  statement: The package shall provide an adoption guide at `docs/adoption.md` that walks both the greenfield path (starting from `mix new`) and the brownfield path (bolting onto an existing tree), and that names the severity-graduation step where `branch_guard` and `guardrails` codes move from `:warning` to `:error`.
  priority: must
  stability: evolving
- id: specled.package.concepts_guide
  statement: The package shall provide a concepts document at `docs/concepts.md` that explains the spec triangle (specs ↔ code ↔ tests), the `realized_by` tiers, the graceful-degrade rule that emits `detector_unavailable` instead of failing when a detector's prerequisites are missing, and how to accept intentional realization drift (the durable `mix spec.check --accept-drift` path, the PR-scoped `Spec-Drift:` trailer, and the implementation-tier delete-and-reseed ritual).
  priority: must
  stability: evolving
- id: specled.package.doc_identifier_integrity
  statement: Documentation and skill files shall reference only finding codes defined by the implementation and shall show config severity values in the bare YAML token form.
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
- kind: source_file
  target: docs/adoption.md
  covers:
    - specled.package.adoption_guide
- kind: source_file
  target: docs/concepts.md
  covers:
    - specled.package.concepts_guide
```
