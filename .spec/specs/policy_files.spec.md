# Policy Files

File-kind classification and co-change rule map for branch-guard.

## Intent

Give `BranchCheck` a single place to ask "is this changed path code, test, doc, or
generated?" and "what co-change rule applies to this kind?" Previously this lived
implicitly inside `change_analysis.ex` with scattered prefix checks. Centralizing the
classification lets the priv/ question be resolved once (conservatively: `:lib` by
default, `:generated` only for explicit carve-outs like `priv/plts/`).

```spec-meta
id: specled.policy_files
kind: module
status: draft
summary: Classifies changed paths into `:lib`, `:test`, `:doc`, `:generated`, or `:unknown` and exposes co-change rules per kind.
surface:
  - lib/specled_ex/policy_files.ex
  - test/specled_ex/policy_files_test.exs
  - lib/specled_ex/change_analysis.ex
decisions:
  - specled.decision.priv_conservative_classification
```

## Requirements

```spec-requirements
- id: specled.policy_files.classify_kinds
  statement: >-
    SpecLedEx.PolicyFiles.classify/1 shall return `:lib`, `:test`,
    `:doc`, `:generated`, or `:unknown` for any given repo-relative path.
    The mapping is total — every path resolves to one of these atoms, never
    `nil`.
  priority: must
  stability: evolving
- id: specled.policy_files.priv_defaults_to_lib
  statement: >-
    Paths under `priv/` shall classify as `:lib` by default. Only
    `priv/plts/` shall classify as `:generated`. This preserves existing
    file-touch semantics on migration files, static assets, and other
    `priv/` content so that upgrades do not silently lose co-change signal.
  priority: must
  stability: evolving
- id: specled.policy_files.plan_docs_excluded
  statement: >-
    Paths under `docs/plans/` shall classify as `:doc` but shall be
    excluded by co_change_rule/1 from any co-change enforcement — they
    are branch-local scratch and never participate in the subject
    co-change gate.
  priority: must
  stability: evolving
- id: specled.policy_files.co_change_rule_total
  statement: >-
    SpecLedEx.PolicyFiles.co_change_rule/1 shall accept any kind atom
    returned by classify/1 and return one of `{:requires_subject_touch,
    severity}`, `:test_only_allowed`, `:doc_only_allowed`,
    `:ignored`, or `:unknown_escalates`. The rule set is fixed and does not
    expand without a spec update.
  priority: must
  stability: evolving
- id: specled.policy_files.change_analysis_delegates
  statement: >-
    SpecLedEx.ChangeAnalysis shall delegate all path-to-kind and
    kind-to-rule questions to SpecLedEx.PolicyFiles. No path prefix or
    extension check shall remain inside ChangeAnalysis after S1.
  priority: must
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: specled.policy_files.scenario.priv_repo_migrations_is_lib
  given:
    - a changed path `priv/repo/migrations/20260401_add_users.exs`
  when:
    - SpecLedEx.PolicyFiles.classify/1 is called with that path
  then:
    - the returned kind is `:lib`
  covers:
    - specled.policy_files.priv_defaults_to_lib
    - specled.policy_files.classify_kinds
- id: specled.policy_files.scenario.priv_plts_is_generated
  given:
    - a changed path `priv/plts/dialyzer.plt`
  when:
    - SpecLedEx.PolicyFiles.classify/1 is called
  then:
    - the returned kind is `:generated`
  covers:
    - specled.policy_files.priv_defaults_to_lib
- id: specled.policy_files.scenario.docs_plans_ignored
  given:
    - a changed path `docs/plans/2026-04-21-notes.md`
  when:
    - SpecLedEx.PolicyFiles.classify/1 and co_change_rule/1 are called
  then:
    - classify returns `:doc`
    - co_change_rule returns `:ignored`
  covers:
    - specled.policy_files.plan_docs_excluded
- id: specled.policy_files.scenario.unknown_path_escalates
  given:
    - a changed path `weird/top/level/file.txt` with no matching rule
  when:
    - SpecLedEx.PolicyFiles.classify/1 and co_change_rule/1 are called
  then:
    - classify returns `:unknown`
    - co_change_rule returns `:unknown_escalates`
  covers:
    - specled.policy_files.classify_kinds
    - specled.policy_files.co_change_rule_total
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/policy_files_test.exs
  execute: false
  covers:
    - specled.policy_files.classify_kinds
    - specled.policy_files.priv_defaults_to_lib
    - specled.policy_files.plan_docs_excluded
    - specled.policy_files.co_change_rule_total
    - specled.policy_files.change_analysis_delegates
```
