# Config

Workspace-scoped configuration loaded from `.spec/config.yml`.

## Intent

Let a project opt into tag scanning and tune enforcement without recompiling or editing
code. Keep the file optional: absent or malformed config degrades to safe defaults without
halting the spec tooling, but malformed values are surfaced so the maintainer notices.

```yaml spec-meta
id: specled.config
kind: module
status: active
summary: Loads `.spec/config.yml` with defaults and exposes test-tag scanning settings to the index, verifier, and CLI tasks.
surface:
  - lib/specled_ex/config.ex
  - lib/mix/tasks/spec.init.ex
  - priv/spec_init/config.yml.eex
  - test/specled_ex/config_test.exs
decisions:
  - specled.decision.configurable_test_tag_enforcement
```

## Requirements

```yaml spec-requirements
- id: specled.config.defaults_when_missing
  statement: SpecLedEx.Config shall return the default configuration struct when `.spec/config.yml` is missing, empty, or unreadable, without raising.
  priority: must
  stability: evolving
- id: specled.config.yaml_parses_known_fields
  statement: SpecLedEx.Config shall parse `test_tags.enabled` (boolean), `test_tags.paths` (list of strings), and `test_tags.enforcement` (`warning` or `error`) from `.spec/config.yml` and expose them on the returned struct.
  priority: must
  stability: evolving
- id: specled.config.malformed_yaml_degrades
  statement: SpecLedEx.Config shall return defaults when `.spec/config.yml` fails to parse as YAML and shall record a parse diagnostic that the caller can surface.
  priority: must
  stability: evolving
- id: specled.config.unknown_enforcement_warns
  statement: SpecLedEx.Config shall log a warning and fall back to the default enforcement when `test_tags.enforcement` is present but not `warning` or `error`.
  priority: should
  stability: evolving
- id: specled.config.paths_filtered_to_strings
  statement: SpecLedEx.Config shall filter non-string elements out of `test_tags.paths` and fall back to the default paths when filtering yields an empty list.
  priority: should
  stability: evolving
- id: specled.config.init_scaffolds_config_yml
  statement: mix spec.init shall scaffold a default `.spec/config.yml` alongside the rest of the workspace when one does not already exist.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.config.scenario.missing_file_uses_defaults
  given:
    - a workspace with no `.spec/config.yml`
  when:
    - SpecLedEx.Config.load/2 is called
  then:
    - the returned config equals SpecLedEx.Config.defaults/0
  covers:
    - specled.config.defaults_when_missing
- id: specled.config.scenario.known_fields_parse
  given:
    - "a `.spec/config.yml` that sets test_tags.enabled to true, test_tags.paths to [\"test/specled_ex\"], and test_tags.enforcement to error"
  when:
    - SpecLedEx.Config.load/2 is called
  then:
    - "the struct has test_tags.enabled true"
    - "the struct has test_tags.paths equal to [\"test/specled_ex\"]"
    - "the struct has test_tags.enforcement equal to :error"
  covers:
    - specled.config.yaml_parses_known_fields
- id: specled.config.scenario.malformed_yaml_returns_defaults
  given:
    - a `.spec/config.yml` that is not valid YAML
  when:
    - SpecLedEx.Config.load/2 is called
  then:
    - the returned config equals SpecLedEx.Config.defaults/0
    - a parse diagnostic is recorded on the returned result
  covers:
    - specled.config.malformed_yaml_degrades
- id: specled.config.scenario.unknown_enforcement_warns
  given:
    - "a `.spec/config.yml` that sets test_tags.enforcement to the string catastrophic"
  when:
    - SpecLedEx.Config.load/2 is called
  then:
    - "the struct test_tags.enforcement equals the default value"
    - "a Logger.warning is emitted naming the unknown value"
  covers:
    - specled.config.unknown_enforcement_warns
- id: specled.config.scenario.non_string_paths_filtered
  given:
    - "a `.spec/config.yml` with test_tags.paths containing [\"test\", 42, null]"
  when:
    - SpecLedEx.Config.load/2 is called
  then:
    - "the struct test_tags.paths equals [\"test\"]"
  covers:
    - specled.config.paths_filtered_to_strings
- id: specled.config.scenario.init_writes_config_yml
  given:
    - a fresh workspace without `.spec/config.yml`
  when:
    - mix spec.init runs
  then:
    - `.spec/config.yml` exists
    - the scaffolded YAML parses back to defaults via SpecLedEx.Config.load/2
  covers:
    - specled.config.init_scaffolds_config_yml
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/config_test.exs
  execute: true
  covers:
    - specled.config.defaults_when_missing
    - specled.config.yaml_parses_known_fields
    - specled.config.malformed_yaml_degrades
    - specled.config.unknown_enforcement_warns
    - specled.config.paths_filtered_to_strings
    - specled.config.init_scaffolds_config_yml
```
