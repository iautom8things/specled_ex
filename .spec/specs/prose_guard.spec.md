# Prose Guard

Cheap prose-rot detection at validate time.

## Intent

A `must` requirement whose statement is one short sentence — "X works" — is not
falsifiable and silently erodes the value of the spec suite. `mix spec.validate` will
emit a `spec_requirement_too_short` finding so the author has a concrete signal that
the statement needs more. The threshold is intentionally crude (char/word counts) and
per-workspace configurable; this is a prompt, not a proof.

```spec-meta
id: specled.prose_guard
kind: workflow
status: draft
summary: Emits `spec_requirement_too_short` when a `must` requirement's statement falls below the configured char/word threshold.
surface:
  - lib/specled_ex/verifier.ex
  - lib/specled_ex/config/prose.ex
  - lib/mix/tasks/spec.validate.ex
  - test/specled_ex/config/prose_test.exs
```

## Requirements

```spec-requirements
- id: specled.prose_guard.finding_emitted
  statement: >-
    mix spec.validate shall emit one `spec_requirement_too_short` finding
    for every `must` requirement whose `statement` falls below the
    configured char-count OR word-count threshold, naming the subject
    file, requirement id, and the failing dimension (chars or words).
  priority: must
  stability: evolving
- id: specled.prose_guard.config_thresholds
  statement: >-
    The `prose` config section shall accept `min_chars` (default 40) and
    `min_words` (default 6) as integers. The zoi schema shall reject
    negative and non-integer values; missing keys fall back to defaults.
  priority: must
  stability: evolving
- id: specled.prose_guard.severity_configurable
  statement: >-
    The finding severity for `spec_requirement_too_short` shall be
    resolvable via SpecLedEx.BranchCheck.Severity (per-code default
    `:info`). Setting it to `:off` in config.severities shall suppress
    the finding entirely.
  priority: must
  stability: evolving
- id: specled.prose_guard.non_must_exempt
  statement: >-
    Requirements with priority other than `must` (e.g., `should`,
    `may`) shall not produce prose-rot findings. The heuristic targets
    normative statements only.
  priority: should
  stability: evolving
```

## Scenarios

```spec-scenarios
- id: specled.prose_guard.scenario.too_short_must_flagged
  given:
    - "a subject file with a must requirement whose statement is `Does the thing.` (14 chars, 3 words)"
    - default prose thresholds (min_chars 40, min_words 6)
  when:
    - mix spec.validate runs
  then:
    - a `spec_requirement_too_short` finding references that requirement id
    - the message names the failing dimension
  covers:
    - specled.prose_guard.finding_emitted
- id: specled.prose_guard.scenario.off_severity_silences
  given:
    - the same too-short must requirement
    - "config.severities set to `spec_requirement_too_short: :off`"
  when:
    - mix spec.validate runs
  then:
    - no `spec_requirement_too_short` finding is produced
  covers:
    - specled.prose_guard.severity_configurable
- id: specled.prose_guard.scenario.should_requirement_not_flagged
  given:
    - a subject with a `should` requirement whose statement is a single short sentence
    - default prose thresholds
  when:
    - mix spec.validate runs
  then:
    - no prose-rot finding is produced for the `should` requirement
  covers:
    - specled.prose_guard.non_must_exempt
```

## Verification

```spec-verification
- kind: command
  target: mix test test/specled_ex/config/prose_test.exs
  execute: true
  covers:
    - specled.prose_guard.config_thresholds
    - specled.prose_guard.finding_emitted
    - specled.prose_guard.severity_configurable
    - specled.prose_guard.non_must_exempt
```
