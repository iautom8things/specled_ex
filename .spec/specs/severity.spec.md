# Severity Resolver

Per-finding severity resolution with layered overrides.

## Intent

Give users a single, documented precedence chain for how each finding's severity is
computed at check time: a per-commit trailer can escalate or relax a finding, config
silences codes entirely with `:off`, and baked-in defaults cover anything else. Without
this module, every finding-emitting call site re-invents its own policy.

```yaml spec-meta
id: specled.severity
kind: module
status: active
summary: Resolves severity per finding from trailer overrides, config map, and per-code defaults.
surface:
  - lib/specled_ex/branch_check/severity.ex
  - test/specled_ex/branch_check/severity_test.exs
  - test/specled_ex/branch_check/severity_integration_test.exs
```

## Requirements

```yaml spec-requirements
- id: specled.severity.resolve_precedence
  statement: >-
    SpecLedEx.BranchCheck.Severity.resolve/3 shall apply the precedence
    trailer_override > config.severities > per_code_default, returning the
    first non-nil value. Trailer overrides and config values shall only
    affect the codes they name; other codes fall through to defaults.
  priority: must
  stability: evolving
- id: specled.severity.off_is_absorbing
  statement: >-
    When a code's severity is `:off` in config.severities, resolve/3 shall
    return `:off` regardless of any trailer override. `:off` is the
    strongest declaration; users who explicitly silence a code are not
    re-noised by per-commit trailers.
  priority: must
  stability: evolving
- id: specled.severity.known_values
  statement: >-
    Severity values recognized by resolve/3 are `:off`, `:info`,
    `:warning`, and `:error`. Unknown values in config.severities shall
    fall back to the per-code default and emit one Logger.warning at
    module load time so the misconfiguration is visible.
  priority: must
  stability: evolving
- id: specled.severity.non_emitting
  statement: >-
    When resolve/3 returns `:off`, the caller shall treat the finding as
    not produced — no entry emitted to the report, no count toward
    exit-status math.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.severity.scenario.trailer_escalates_warning_to_error
  given:
    - a code with per-code default `:warning`
    - no entry for that code in config.severities
    - "a trailer_override map `%{code => :error}`"
  when:
    - SpecLedEx.BranchCheck.Severity.resolve/3 is called for that code
  then:
    - the returned severity is `:error`
  covers:
    - specled.severity.resolve_precedence
- id: specled.severity.scenario.off_beats_trailer
  given:
    - "a code silenced via config.severities `%{code => :off}`"
    - "a trailer_override map `%{code => :error}`"
  when:
    - SpecLedEx.BranchCheck.Severity.resolve/3 is called for that code
  then:
    - the returned severity is `:off`
  covers:
    - specled.severity.off_is_absorbing
    - specled.severity.non_emitting
- id: specled.severity.scenario.unknown_value_falls_back
  given:
    - "a config.severities map `%{some_code => :shout}`"
    - no trailer override
  when:
    - SpecLedEx.BranchCheck.Severity.resolve/3 is called for some_code
  then:
    - the returned severity is the per-code default for some_code
    - a Logger.warning names the bad value and the code
  covers:
    - specled.severity.known_values
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/branch_check/severity_test.exs
  execute: true
  covers:
    - specled.severity.resolve_precedence
    - specled.severity.off_is_absorbing
    - specled.severity.known_values
    - specled.severity.non_emitting
```
