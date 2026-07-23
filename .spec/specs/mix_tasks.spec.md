# Mix Tasks

User-facing commands for the Spec Led Development workflow.

## Intent

Provide the user-facing Mix tasks that scaffold, guide, summarize, and strictly enforce the local Spec Led workflow.

The `spec.init` scaffold's local skill and README, and the `spec.prime` loop, describe the missing-ADR condition as a two-armed fork: an ADR for durable cross-cutting policy, otherwise a `Spec-Drift: branch_guard_missing_decision_update=info` trailer with a one-line reason.

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
  - lib/mix/tasks/spec.cover.test.ex
  - lib/mix/tasks/spec.cover.ingest.ex
  - lib/mix/tasks/spec.suggest_binding.ex
  - lib/mix/tasks/spec.triangle.ex
  - lib/mix/tasks/spec.review.ex
  - lib/mix/tasks/spec.dedup_realized_by.ex
  - lib/mix/tasks/spec.sync.ex
  - lib/mix/tasks/spec.prune.ex
  - lib/mix/tasks/spec.evidence.migrate.ex
  - lib/mix/tasks/spec.evidence.install_hook.ex
  - priv/hooks/pre-push
  - lib/specled_ex/mix_runtime.ex
  - lib/specled_ex/task_args.ex
  - lib/specled_ex/prime.ex
  - priv/spec_init/agents/skills/spec-led-development/SKILL.md.eex
  - priv/spec_init/specs/spec_system.spec.md.eex
  - priv/spec_init/specs/package.spec.md.eex
  - skills/write-spec-led-specs/references/authoring-reference.md
  - test_support/specled_ex_case.ex
  - test/mix/tasks/spec_cover_ingest_test.exs
realized_by:
  implementation:
    - "Mix.Tasks.Spec.Init.run/1"
    - "Mix.Tasks.Spec.Prime.run/1"
    - "Mix.Tasks.Spec.Next.run/1"
    - "Mix.Tasks.Spec.Check.run/1"
    - "Mix.Tasks.Spec.Status.run/1"
    - "Mix.Tasks.Spec.Decision.New.run/1"
    - "Mix.Tasks.Spec.Index.run/1"
    - "Mix.Tasks.Spec.Validate.run/1"
    - "Mix.Tasks.Spec.DedupRealizedBy.run/1"
    - "Mix.Tasks.Spec.Sync.run/1"
    - "Mix.Tasks.Spec.Prune.run/1"
    - "Mix.Tasks.Spec.Evidence.Migrate.run/1"
    - "Mix.Tasks.Spec.Evidence.InstallHook.run/1"
    - "Mix.Tasks.Spec.Cover.Ingest.run/1"
    - "SpecLedEx.MixRuntime.ensure_started!/0"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.local_skill_scaffold
  - specled.decision.guided_reconciliation_loop
  - specled.decision.no_app_start
  - specled.decision.dep_runtime_bootstrap
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.realized_by_tier_implication
  - specled.decision.verification_runtime_config
  - specled.decision.sync_noop_short_circuit_and_auto_prune
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
  statement: mix spec.index shall build the authored subject and decision index, and shall write derived state only when the caller supplies `--output`.
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
  statement: mix spec.validate shall validate specs and derive findings, and shall write derived state with the verification report only when the caller supplies `--output`.
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
- id: specled.tasks.config_diagnostics_surfaced
  statement: mix spec.validate and mix spec.check shall print each config diagnostic recorded by SpecLedEx.Config.load (for example an invalid `.spec/config.yml` severity override that was dropped) as a visible `[CONFIG]`-prefixed warning line before their normal report output, and shall do so without altering the task exit status.
  priority: must
  stability: stable
- id: specled.tasks.check_evidence_write
  statement: >-
    After validation and branch-aware co-change enforcement complete, mix
    spec.check shall write a local evidence attestation to
    `refs/heads/spec-evidence` using Git plumbing only. The write path shall
    perform zero network I/O, shall never check out the evidence ref, and
    shall emit an `evidence/local_write_failed` warning without changing the
    task exit status if the local evidence write fails. mix spec.check shall
    not write `.spec/state.json`.
  priority: must
  stability: evolving
- id: specled.tasks.status_summary
  statement: mix spec.status shall summarize coverage, verification strength, weak spots, and ADR usage for the current workspace, executing command verifications by default unless explicitly opted out.
  priority: should
  stability: evolving
- id: specled.tasks.no_app_start
  statement: No mix spec.* task shall call Mix.Task.run("app.start") or otherwise require the host OTP application to be running, since spec tasks perform only file I/O, Git CLI calls, and in-memory parsing.
  priority: must
  stability: stable
- id: specled.tasks.dep_runtime_bootstrap
  statement: Every mix spec.* task shall call SpecLedEx.MixRuntime.ensure_started!/0 as the first line of run/1, so the BEAM applications specled depends on at runtime (currently :yaml_elixir and :jason) are started even when specled is consumed as a Hex dependency. The shared helper shall remain the single source of truth for the dep list. Tasks shall additionally declare `@requirements ["app.config"]` to load host config, except `spec.cover.test` and `spec.cover.ingest`, which run inside child-BEAM fixtures whose code path Mix's `app.config` would purge before the helper module could be lazily loaded.
  priority: must
  stability: stable
- id: specled.tasks.cover_ingest_escape_hatch
  statement: >-
    mix spec.cover.ingest shall ingest an arbitrary exported `.coverdata`
    file via `SpecLedEx.Coverage.Aggregate.ingest/2` and persist the
    resulting v2 envelope via `SpecLedEx.Coverage.Store.write_v2/2`, so a CI
    run that already produces `.coverdata` (for example for coveralls) gets
    spec coverage without a second serialized test run. It shall exit 0 for
    `mix help spec.cover.ingest` and for a successful ingest, and shall exit
    non-zero with a clear message for a missing, garbage, or empty-coverage
    input path.
  priority: must
  stability: evolving
- id: specled.tasks.test_tags_flag
  statement: mix spec.check and mix spec.validate shall accept `--test-tags` and `--no-test-tags` flags that enable or disable test-tag scanning for that invocation, overriding the config default.
  priority: must
  stability: evolving
- id: specled.tasks.accept_drift_flag
  statement: >-
    mix spec.check shall accept an `--accept-drift` flag that threads
    `accept_drift?: true` into the branch guard's realization run, accepting the
    current flat-tier realization hashes as the new committed baseline for
    intentional drift (see `specled.realized_by.drift_acceptance`). Without the
    flag the branch guard shall not refresh committed hashes on a run that
    produced drift.
  priority: must
  stability: evolving
- id: specled.tasks.test_tags_precedence
  statement: When building the index, the effective test-tag enabled value shall follow CLI flag > `.spec/config.yml` > built-in default precedence.
  priority: must
  stability: evolving
- id: specled.tasks.command_timeout_config
  statement: mix spec.check and mix spec.validate shall read `verification.command_timeout_ms` from `.spec/config.yml` and pass that timeout to command and tagged-test verification execution.
  priority: must
  stability: evolving
- id: specled.tasks.verification_severity_config
  statement: mix spec.check and mix spec.validate shall read `verification.severities` from `.spec/config.yml` and pass those verifier finding severity overrides into validation before strict status is computed.
  priority: must
  stability: evolving
- id: specled.tasks.check_verbose_flag
  statement: mix spec.check shall accept a `--verbose` flag and honor `SPECLED_SHOW_INFO=1` that together govern stdout filtering; without either, findings whose resolved severity is `:info` shall be suppressed from stdout. With either flag or env var, every finding regardless of severity shall be printed.
  priority: must
  stability: evolving
- id: specled.tasks.evidence_migrate
  statement: >-
    mix spec.evidence.migrate shall hoist any legacy embedded realization
    baseline, untrack `.spec/state.json` while preserving the file, append
    `.spec/state.json` to `.gitignore`, install the spec evidence pre-push
    hook, and seed the local orphan evidence ref for the post-migration tree
    without modifying `.spec/realization_hashes.json`.
  priority: must
  stability: evolving
- id: specled.tasks.evidence_install_hook
  statement: >-
    mix spec.evidence.install_hook shall install the static pre-push shim from
    `priv/hooks/pre-push` when no hook exists, and shall refuse to overwrite an
    existing hook while printing the snippet to append manually.
  priority: must
  stability: evolving
- id: specled.tasks.review_html_artifact
  statement: mix spec.review shall produce a self-contained HTML artifact rendering the current Git change set as a spec-aware PR review surface, delegating the substantive contract to specled.spec_review.
  priority: should
  stability: evolving
- id: specled.tasks.dedup_realized_by_proposal
  statement: >-
    mix spec.dedup_realized_by shall print proposed YAML edits removing
    the redundant `api_boundary` line for every entry already listed
    under `implementation`, grouped by subject. Each proposal block
    shall include a `# already implied by implementation` comment on
    the removal so the diff is self-documenting.
  priority: must
  stability: evolving
- id: specled.tasks.dedup_realized_by_no_write
  statement: >-
    mix spec.dedup_realized_by shall not accept a `--write` flag. The
    task is a proposal renderer only; agents apply edits via their own
    tooling, mirroring the contract of mix spec.suggest_binding.
  priority: must
  stability: evolving
- id: specled.tasks.dedup_realized_by_exit_code
  statement: >-
    mix spec.dedup_realized_by shall exit 0 by default whether or not
    duplications were found. With `--fail-on-dups`, the task shall exit
    non-zero whenever any subject has at least one duplication.
  priority: must
  stability: evolving
- id: specled.tasks.dedup_realized_by_shared_seam
  statement: >-
    mix spec.dedup_realized_by shall compute duplications via
    `SpecLedEx.Validator.RealizedByDedupe.duplicates/1`, the same
    helper used by the `mix spec.validate` `realized_by_redundant_dup`
    check, so that the proposal output and the validator finding
    cannot disagree.
  priority: must
  stability: evolving
- id: specled.tasks.check_builds_compile_context
  statement: >-
    mix spec.check shall construct the compile `Context` via
    `SpecLedEx.Compiler.Context.from_mix_project/1` when its effective
    root is the current working directory, and shall thread it into the
    branch guard so realization tiers receive the compile manifest.
    When `--root` points anywhere else, no context shall be passed
    (Mix.Project describes the cwd's project, not an arbitrary root —
    a wrong-project context is worse than none).
  priority: must
  stability: evolving
- id: specled.tasks.sync_evidence
  statement: >-
    mix spec.sync shall call the evidence Sync production path, print ahead
    and behind entry counts labeled as of the last fetch, raise on failure by
    default, and accept --best-effort to emit exactly one warning and return
    successfully.
  priority: must
  stability: evolving
- id: specled.tasks.prune_evidence
  statement: >-
    mix spec.prune shall be an explicit command that fetches, then computes
    the reachable-tree-hash keep-set (trees reachable from local branch
    heads and remote-tracking refs) via the same
    `SpecLedEx.Evidence.Sync.reachable_keep_set/1` that sync's own
    size-threshold auto-prune uses (see
    specled.evidence_store.sync_auto_prune), removes only evidence outside
    that set, and pushes through the lease-guarded Sync production path.
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
    - specled.tasks.review_html_artifact
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.check_builds_compile_context
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.test_tags_flag
    - specled.tasks.test_tags_precedence
    - specled.tasks.command_timeout_config
    - specled.tasks.verification_severity_config
    - specled.tasks.accept_drift_flag
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.config_diagnostics_surfaced
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.check_verbose_flag
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.check_evidence_write
    - specled.tasks.evidence_migrate
    - specled.tasks.evidence_install_hook
- kind: command
  target: >-
    sh -c 'missing=$(grep -L "SpecLedEx.MixRuntime.ensure_started" lib/mix/tasks/*.ex); if [ -n "$missing" ]; then echo "tasks missing MixRuntime bootstrap:"; echo "$missing"; exit 1; fi'
  execute: true
  covers:
    - specled.tasks.dep_runtime_bootstrap
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.dedup_realized_by_proposal
    - specled.tasks.dedup_realized_by_no_write
    - specled.tasks.dedup_realized_by_exit_code
    - specled.tasks.dedup_realized_by_shared_seam
- kind: command
  target: mix test test/mix/tasks/spec_sync_task_test.exs test/mix/tasks/spec_prune_task_test.exs
  execute: true
  covers:
    - specled.tasks.sync_evidence
    - specled.tasks.prune_evidence
- kind: tagged_tests
  execute: true
  covers:
    - specled.tasks.cover_ingest_escape_hatch
```
