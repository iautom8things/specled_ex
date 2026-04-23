# Verification

The verifier validates authored specs and derives findings.

## Intent

Take an indexed set of authored specs, validate structure and references,
and produce a verification report with findings. This is the core of
the intent verification loop.

```yaml spec-meta
id: specled.verification
kind: workflow
status: active
summary: Validates authored specs, checks references, derives findings, and writes state.
surface:
  - lib/specled_ex/verifier.ex
  - lib/specled_ex/verification_strength.ex
  - lib/specled_ex/tag_findings.ex
  - lib/specled_ex/decision_parser.ex
  - lib/specled_ex/schema/decision.ex
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.file_backed_linked_strength
  - specled.decision.explicit_subject_ownership
  - specled.decision.tempfile_command_execution
  - specled.decision.configurable_test_tag_enforcement
```

## Requirements

```yaml spec-requirements
- id: specled.verify.meta_required
  statement: Verification shall emit errors when a subject is missing spec-meta id, kind, or status.
  priority: must
  stability: stable
- id: specled.verify.reference_checks
  statement: Verification shall detect duplicate subject ids, duplicate requirement ids, unresolved scenario covers, and unresolved verification covers.
  priority: must
  stability: stable
- id: specled.verify.coverage_warnings
  statement: Verification shall warn when a requirement has no covering verification entry.
  priority: must
  stability: stable
- id: specled.verify.target_existence
  statement: Verification shall warn when a file-based verification target does not exist on disk.
  priority: should
  stability: stable
- id: specled.verify.malformed_entries_nonfatal
  statement: Verification shall ignore malformed non-map parsed block entries, rely on recorded parse errors, and continue producing a report.
  priority: must
  stability: stable
- id: specled.verify.decision_governance
  statement: Verification shall validate ADR frontmatter, required ADR sections, ADR affects references, supersession links, and subject decision references.
  priority: must
  stability: evolving
- id: specled.verify.strength_semantics
  statement: Verification strength ordering shall treat `claimed`, `linked`, and `executed` as an ordered proof scale and use that ordering to enforce effective minimum strength thresholds.
  priority: must
  stability: stable
- id: specled.verify.command_execution_resilience
  statement: >
    Command verifications shall capture output via temp files and wait for
    process exit status, not pipe EOF. Commands shall run under a configurable
    timeout (default 120s). Output and exit code files shall be cleaned up even
    if reading fails.
  priority: must
  stability: stable
- id: specled.verify.requirement_without_test_tag
  statement: When test-tag data is present on the index, verification shall emit a `requirement_without_test_tag` finding for each `must` requirement whose id appears in no `@tag spec:` annotation within the configured scan paths.
  priority: must
  stability: evolving
- id: specled.verify.verification_cover_untagged
  statement: When test-tag data is present on the index, verification shall emit a `verification_cover_untagged` finding for each `test_file` or `test` verification whose `covers:` ids are not backed by a matching `@tag spec:` annotation in the referenced file.
  priority: must
  stability: evolving
- id: specled.verify.tag_scan_parse_error
  statement: Verification shall emit a `tag_scan_parse_error` finding (severity warning) for each file that the tag scanner recorded as unparseable.
  priority: must
  stability: evolving
- id: specled.verify.tag_dynamic_value_skipped
  statement: Verification shall emit a `tag_dynamic_value_skipped` finding for each `@tag spec:` annotation whose value the tag scanner could not resolve to a literal string or list of strings.
  priority: should
  stability: evolving
- id: specled.verify.tag_findings_respect_enforcement
  statement: The severity of `requirement_without_test_tag` and `verification_cover_untagged` findings shall follow the configured `test_tags.enforcement` value (`warning` or `error`), defaulting to warning.
  priority: must
  stability: evolving
- id: specled.verify.tag_findings_suppressed_when_disabled
  statement: Verification shall not emit any tag-related findings when the index has no test-tag data.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.verify.uncovered_requirement
  given:
    - a spec with a requirement that has no covering verification
  when:
    - verification runs
  then:
    - a warning finding is produced for the uncovered requirement
  covers:
    - specled.verify.coverage_warnings
- id: specled.verify.missing_target
  given:
    - a spec with a source_file verification pointing to a path that does not exist
  when:
    - verification runs
  then:
    - a warning finding is produced for the missing target
  covers:
    - specled.verify.target_existence
- id: specled.verify.malformed_entry_report
  given:
    - an indexed subject containing malformed parsed block entries and parse errors
  when:
    - verification runs
  then:
    - the report includes the parse error finding
    - verification does not crash
  covers:
    - specled.verify.malformed_entries_nonfatal
- id: specled.verify.scenario.command_captures_output_via_tempfile
  given:
    - a spec with a command verification targeting "printf ok" with execute true
  when:
    - verification runs with run_commands true
  then:
    - the command output is captured correctly
    - the exit code is 0
    - no temp files remain after verification
  covers:
    - specled.verify.command_execution_resilience
- id: specled.verify.scenario.command_timeout
  given:
    - a spec with a command verification targeting a slow command
  when:
    - verification runs with run_commands true and a short timeout
  then:
    - the command is killed after the timeout
    - a non-zero exit code is recorded
  covers:
    - specled.verify.command_execution_resilience
- id: specled.verify.scenario.command_failed_exit_code
  given:
    - a spec with a command verification targeting "exit 2"
  when:
    - verification runs with run_commands true
  then:
    - the exit code is 2
    - the verification is reported as failed
  covers:
    - specled.verify.command_execution_resilience
- id: specled.verify.scenario.requirement_without_tag_emits_finding
  given:
    - an index with a `must` requirement `billing.invoice` and a tag_map that does not contain `billing.invoice`
  when:
    - verification runs
  then:
    - a `requirement_without_test_tag` finding is emitted for `billing.invoice`
  covers:
    - specled.verify.requirement_without_test_tag
- id: specled.verify.scenario.verification_cover_untagged_emits_finding
  given:
    - "a test_file verification targeting test/billing_test.exs that covers billing.invoice"
    - "a tag_map showing no `@tag spec` annotation for billing.invoice in test/billing_test.exs"
  when:
    - verification runs
  then:
    - a `verification_cover_untagged` finding is emitted for `billing.invoice` on that file
  covers:
    - specled.verify.verification_cover_untagged
- id: specled.verify.scenario.tag_scan_parse_error_emitted
  given:
    - "an index with a test_tags_errors entry for file test/broken.exs and any reason"
  when:
    - verification runs
  then:
    - a warning `tag_scan_parse_error` finding is emitted referencing `test/broken.exs`
  covers:
    - specled.verify.tag_scan_parse_error
- id: specled.verify.scenario.enforcement_error_promotes_severity
  given:
    - "a config that sets test_tags.enforcement to :error"
    - "a must requirement that has no backing `@tag spec` annotation"
  when:
    - verification runs
  then:
    - the `requirement_without_test_tag` finding is reported with severity error
  covers:
    - specled.verify.tag_findings_respect_enforcement
- id: specled.verify.scenario.no_tag_data_no_tag_findings
  given:
    - an index with no `test_tags` key
  when:
    - verification runs
  then:
    - no `requirement_without_test_tag`, `verification_cover_untagged`, `tag_scan_parse_error`, or `tag_dynamic_value_skipped` finding is emitted
  covers:
    - specled.verify.tag_findings_suppressed_when_disabled
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/verifier_test.exs test/specled_ex/verification_strength_test.exs
  execute: true
  covers:
    - specled.verify.meta_required
    - specled.verify.reference_checks
    - specled.verify.coverage_warnings
    - specled.verify.target_existence
    - specled.verify.malformed_entries_nonfatal
    - specled.verify.decision_governance
    - specled.verify.strength_semantics
    - specled.verify.command_execution_resilience
- kind: command
  target: mix test test/specled_ex/tag_findings_test.exs
  execute: true
  covers:
    - specled.verify.requirement_without_test_tag
    - specled.verify.verification_cover_untagged
    - specled.verify.tag_scan_parse_error
    - specled.verify.tag_dynamic_value_skipped
    - specled.verify.tag_findings_respect_enforcement
    - specled.verify.tag_findings_suppressed_when_disabled
```
