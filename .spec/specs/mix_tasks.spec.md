# Mix Tasks

User-facing commands for the Spec Led Development workflow.

## Intent

Provide the user-facing Mix tasks that scaffold, guide, summarize, and strictly enforce the local Spec Led workflow.

```yaml spec-meta
id: specled.mix_tasks
kind: workflow
status: active
summary: Mix tasks for scaffolding, session-start priming, indexing, guiding, validating, summarizing, and strictly checking Spec Led Development workspaces.
surface:
  - lib/mix/tasks/spec.init.ex
  - lib/mix/tasks/spec.prime.ex
  - lib/mix/tasks/spec.next.ex
  - lib/mix/tasks/spec.check.ex
  - lib/mix/tasks/spec.status.ex
  - lib/mix/tasks/spec.decision.new.ex
  - lib/mix/tasks/spec.index.ex
  - lib/mix/tasks/spec.validate.ex
  - lib/specled_ex/prime.ex
  - priv/spec_init/agents/skills/spec-led-development/SKILL.md.eex
  - priv/spec_init/specs/spec_system.spec.md.eex
  - priv/spec_init/specs/package.spec.md.eex
  - skills/write-spec-led-specs/references/authoring-reference.md
  - test_support/specled_ex_case.ex
realized_by:
  api_boundary:
    - "Mix.Tasks.Spec.Check.run/1"
  implementation:
    - "Mix.Tasks.Spec.Init.run/1"
    - "Mix.Tasks.Spec.Prime.run/1"
    - "Mix.Tasks.Spec.Next.run/1"
    - "Mix.Tasks.Spec.Check.run/1"
    - "Mix.Tasks.Spec.Status.run/1"
    - "Mix.Tasks.Spec.Decision.New.run/1"
    - "Mix.Tasks.Spec.Index.run/1"
    - "Mix.Tasks.Spec.Validate.run/1"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.local_skill_scaffold
  - specled.decision.guided_reconciliation_loop
  - specled.decision.no_app_start
  - specled.decision.configurable_test_tag_enforcement
```

## Requirements

```yaml spec-requirements
- id: specled.tasks.init_scaffold
  statement: mix spec.init shall create the canonical .spec/ workspace with README.md, AGENTS.md, decisions/README.md, spec_system.spec.md, and package.spec.md.
  priority: must
  stability: stable
- id: specled.tasks.init_local_skill
  statement: In interactive runs, mix spec.init shall offer to scaffold a local Skill for Spec Led Development and write it when the prompt is accepted.
  priority: should
  stability: evolving
- id: specled.tasks.decision_new_scaffold
  statement: mix spec.decision.new shall scaffold an ADR under .spec/decisions with the required frontmatter and body sections.
  priority: should
  stability: evolving
- id: specled.tasks.index_writes_state
  statement: mix spec.index shall build the authored subject and decision index and write .spec/state.json.
  priority: must
  stability: stable
- id: specled.tasks.prime_context
  statement: mix spec.prime shall provide a read-only session-start summary that combines workspace status, current-branch guidance, and the default local loop without writing current-truth files or derived state.
  priority: should
  stability: evolving
- id: specled.tasks.next_guidance
  statement: mix spec.next shall provide a read-only guided reconciliation step that points at the next subject, proof, or ADR update for the current Git change set and tell the maintainer when the branch is ready for the full local check.
  priority: should
  stability: evolving
- id: specled.tasks.prime_json
  statement: mix spec.prime shall support JSON output for agent consumption and shall only execute eligible command verifications when --run-commands is passed.
  priority: should
  stability: evolving
- id: specled.tasks.validate_findings
  statement: mix spec.validate shall validate specs, derive findings, and write .spec/state.json with a verification report before returning.
  priority: must
  stability: stable
- id: specled.tasks.validate_exit_status
  statement: mix spec.validate shall exit non-zero whenever the generated verification report status is fail.
  priority: must
  stability: stable
- id: specled.tasks.check_strict_gate
  statement: mix spec.check shall run indexing, strict validation, and branch-aware co-change enforcement, failing on any errors or warnings.
  priority: must
  stability: stable
- id: specled.tasks.status_summary
  statement: mix spec.status shall summarize coverage, verification strength, weak spots, and ADR usage for the current workspace, executing command verifications by default unless explicitly opted out.
  priority: should
  stability: evolving
- id: specled.tasks.no_app_start
  statement: No mix spec.* task shall call Mix.Task.run("app.start") or otherwise require the host OTP application to be running, since spec tasks perform only file I/O, Git CLI calls, and in-memory parsing.
  priority: must
  stability: stable
- id: specled.tasks.test_tags_flag
  statement: mix spec.check and mix spec.validate shall accept `--test-tags` and `--no-test-tags` flags that enable or disable test-tag scanning for that invocation, overriding the config default.
  priority: must
  stability: evolving
- id: specled.tasks.test_tags_precedence
  statement: When building the index, the effective test-tag enabled value shall follow CLI flag > `.spec/config.yml` > built-in default precedence.
  priority: must
  stability: evolving
- id: specled.tasks.check_verbose_flag
  statement: mix spec.check shall accept a `--verbose` flag and honor `SPECLED_SHOW_INFO=1` that together govern stdout filtering; without either, findings whose resolved severity is `:info` shall be suppressed from stdout while still being written to `.spec/state.json` unchanged. With either flag or env var, every finding regardless of severity shall be printed.
  priority: must
  stability: evolving
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.init_scaffold
    - specled.tasks.init_local_skill
    - specled.tasks.decision_new_scaffold
    - specled.tasks.index_writes_state
    - specled.tasks.prime_context
    - specled.tasks.prime_json
    - specled.tasks.next_guidance
    - specled.tasks.validate_findings
    - specled.tasks.validate_exit_status
    - specled.tasks.check_strict_gate
    - specled.tasks.status_summary
    - specled.tasks.no_app_start
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.test_tags_flag
    - specled.tasks.test_tags_precedence
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.check_verbose_flag
```
