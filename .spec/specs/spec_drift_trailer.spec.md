# Spec-Drift Trailer

Per-PR trailer override for branch-guard severities.

## Intent

Allow the author of a change to declare, in a git trailer, that a specific finding is
expected for this PR (e.g., "refactor — no behavior change"). The trailer is a
self-report that downgrades or re-labels findings for the lifespan of the PR without
editing config. The window is `base..HEAD`, not HEAD-only: CI sees squash commits and
merge commits where the trailer may live one commit deep, not at the tip.

```yaml spec-meta
id: specled.spec_drift_trailer
kind: module
status: active
summary: Parses `Spec-Drift:` git trailers across base..HEAD and exposes a trailer_override map to Severity.
surface:
  - lib/specled_ex/branch_check/trailer.ex
  - test/specled_ex/branch_check/trailer_test.exs
realized_by:
  implementation:
    - "SpecLedEx.BranchCheck.Trailer.parse/1"
    - "SpecLedEx.BranchCheck.Trailer.read/2"
    - "SpecLedEx.BranchCheck.Trailer.apply_token/2"
    - "SpecLedEx.BranchCheck.Trailer.apply_pair/2"
decisions:
  - specled.decision.spec_drift_base_to_head
```

## Requirements

```yaml spec-requirements
- id: specled.spec_drift_trailer.parse_vocabulary
  statement: >-
    SpecLedEx.BranchCheck.Trailer.parse/1 shall accept the trailer values
    `refactor`, `docs_only`, `test_only`, and severity-coded forms
    `<code>=<severity>` (e.g., `branch_guard_realization_drift=info`) and
    return a structured override map keyed by finding code.
  priority: must
  stability: evolving
- id: specled.spec_drift_trailer.parse_unknown_token_warns
  statement: >-
    SpecLedEx.BranchCheck.Trailer.parse/1 shall ignore unknown trailer
    tokens (producing no override for them) and report each unknown
    token via a `:warnings` list on the return value, so mistyped
    trailers do not silently fail.
  priority: must
  stability: evolving
- id: specled.spec_drift_trailer.scans_base_to_head
  statement: >-
    SpecLedEx.BranchCheck.Trailer.read/2 shall read `git log <base>..HEAD
    --format=%B` and return the union of parsed trailer overrides across
    every commit in the range. HEAD-only reading is explicitly wrong and
    is not a supported mode.
  priority: must
  stability: evolving
- id: specled.spec_drift_trailer.self_report_documented
  statement: >-
    Trailers shall be treated as self-report; read/2 shall not verify
    signatures or authorship. The module documentation shall state
    explicitly that the mechanism is cooperative and suited to
    single-author / small-team workflows.
  priority: should
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.spec_drift_trailer.scenario.refactor_downgrades_realization_drift
  given:
    - "a branch with two commits, the second carrying `Spec-Drift: refactor` in its message"
    - a finding code of `branch_guard_realization_drift` with default `:warning`
  when:
    - SpecLedEx.BranchCheck.Trailer.read/2 is called with base=main
    - SpecLedEx.BranchCheck.Severity.resolve/3 is called for the code using the returned override
  then:
    - "the override map contains `%{branch_guard_realization_drift: :info}` (or the documented mapping)"
    - the resolved severity for that code is `:info`
  covers:
    - specled.spec_drift_trailer.scans_base_to_head
    - specled.spec_drift_trailer.parse_vocabulary
- id: specled.spec_drift_trailer.scenario.unknown_trailer_token_warns
  given:
    - "a commit message carrying `Spec-Drift: lolwut`"
  when:
    - SpecLedEx.BranchCheck.Trailer.parse/1 is called with that message body
  then:
    - the returned override map is empty
    - the returned :warnings list names `lolwut`
  covers:
    - specled.spec_drift_trailer.parse_unknown_token_warns
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/branch_check/trailer_test.exs
  execute: true
  covers:
    - specled.spec_drift_trailer.parse_vocabulary
    - specled.spec_drift_trailer.parse_unknown_token_warns
    - specled.spec_drift_trailer.scans_base_to_head
    - specled.spec_drift_trailer.self_report_documented
```
