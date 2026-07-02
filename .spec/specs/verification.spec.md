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
realized_by:
  implementation:
    - "SpecLedEx.Verifier.verify/3"
    - "SpecLedEx.VerificationStrength.meets_minimum?/2"
    - "SpecLedEx.VerificationStrength.normalize/1"
    - "SpecLedEx.VerificationStrength.default/0"
    - "SpecLedEx.VerificationStrength.levels/0"
    - "SpecLedEx.TagFindings.findings/1"
decisions:
  - specled.decision.declarative_current_truth
  - specled.decision.file_backed_linked_strength
  - specled.decision.explicit_subject_ownership
  - specled.decision.tempfile_command_execution
  - specled.decision.configurable_test_tag_enforcement
  - specled.decision.tagged_tests_file_selectors
  - specled.decision.verification_runtime_config
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
    timeout (default 120s). Output temp files shall be cleaned up even if
    reading fails. Exit status shall come from the supervised command process
    rather than a second sidecar file written after command completion.
  priority: must
  stability: stable
- id: specled.verify.command_output_via_tempfile
  statement: >
    Command verifications shall capture stdout+stderr via a temp file and
    wait for process exit status (not pipe EOF) so that large outputs and
    flushing semantics do not corrupt or truncate the captured text, and
    temp files shall be removed after the result is read.
  priority: must
  stability: stable
- id: specled.verify.command_timeout_enforced
  statement: >
    Command verifications shall run under a configurable timeout (default
    120s). When the timeout elapses, the result shall record the timeout
    distinctly and verification shall fail for gating purposes without
    treating the timeout as an observed non-zero test failure.
  priority: must
  stability: stable
- id: specled.verify.command_timeout_distinct_finding
  statement: >
    When a command verification times out, verification shall emit an error
    finding with code `verification_command_timeout` rather than
    `verification_command_failed`. The timeout message shall include the
    exceeded millisecond budget, the
    `verification.command_timeout_ms` `.spec/config.yml` key with the 120000ms
    default, and a `--command-timeout-ms` retry hint.
  priority: must
  stability: stable
- id: specled.verify.command_timeout_cli_precedence
  statement: >
    `mix spec.check` and `mix spec.validate` shall accept
    `--command-timeout-ms` as a one-shot command verification timeout override.
    When present, the CLI value shall override
    `.spec/config.yml` `verification.command_timeout_ms`; when absent, the
    config value shall be used; when neither is present, the verifier's 120
    second default shall apply.
  priority: must
  stability: evolving
- id: specled.verify.command_exit_code_recorded
  statement: >
    Command verifications shall record the spawned process's exact exit
    code on the result, and a non-zero exit code shall mark the
    verification as failed.
  priority: must
  stability: stable
- id: specled.verify.requirement_without_test_tag
  statement: >-
    When test-tag data is present on the index, verification shall emit a
    `requirement_without_test_tag` finding for each `must` requirement that
    is covered by at least one `tagged_tests` verification on its owning
    subject and whose id appears in no `@tag spec:` annotation within the
    configured scan paths. Requirements covered exclusively by
    non-`tagged_tests` kinds (source_file, command, file-based kinds) shall
    not produce this finding.
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
- id: specled.verify.finding_severity_overrides
  statement: Verification shall apply configured finding-code severity overrides before computing summary error/warning counts and strict pass/fail status; `:off` removes matching findings, while `:info`, `:warning`, and `:error` rewrite matching finding severities.
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
    - no temp output files remain after verification
  covers:
    - specled.verify.command_output_via_tempfile
- id: specled.verify.scenario.command_timeout
  given:
    - a spec with a command verification targeting a slow command
  when:
    - verification runs with run_commands true and a short timeout
  then:
    - the result records the timeout distinctly
    - verification is reported failed for gating purposes
  covers:
    - specled.verify.command_timeout_enforced
- id: specled.verify.scenario.command_timeout_kills_process_group
  given:
    - a spec with a command verification whose target spawns a long-lived child process
  when:
    - verification runs with run_commands true and a short timeout
  then:
    - the timeout SIGKILLs the target's whole process group
    - the spawned child process is no longer running after verification returns
  covers:
    - specled.verify.command_execution_resilience
- id: specled.verify.scenario.command_timeout_distinct_finding
  given:
    - a spec with a command verification targeting a slow command
  when:
    - verification runs with run_commands true and a short timeout
  then:
    - a `verification_command_timeout` error finding is emitted
    - no `verification_command_failed` finding is emitted for that timeout
    - the finding message includes the exceeded budget and `--command-timeout-ms` retry hint
  covers:
    - specled.verify.command_timeout_distinct_finding
- id: specled.verify.scenario.command_timeout_cli_precedence
  given:
    - a spec with an executable command verification targeting a slow command
    - `.spec/config.yml` may set `verification.command_timeout_ms`
  when:
    - `mix spec.check` or `mix spec.validate` runs command verification
  then:
    - `--command-timeout-ms` overrides the config timeout when present
    - the config timeout is used when the flag is absent
    - the verifier's 120 second default applies when both are absent
  covers:
    - specled.verify.command_timeout_cli_precedence
- id: specled.verify.scenario.command_failed_exit_code
  given:
    - a spec with a command verification targeting "exit 2"
  when:
    - verification runs with run_commands true
  then:
    - the exit code is 2
    - the verification is reported as failed
  covers:
    - specled.verify.command_exit_code_recorded
- id: specled.verify.scenario.requirement_without_tag_emits_finding
  given:
    - an index with a `must` requirement `billing.invoice`
    - the subject owning that requirement declares a `tagged_tests` verification covering `billing.invoice`
    - a tag_map that does not contain `billing.invoice`
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
- id: specled.verify.scenario.finding_severity_override
  given:
    - a verification run that would normally emit a warning finding
    - a severities config mapping that finding code to info
  when:
    - verification runs in strict mode
  then:
    - the finding is retained with severity info
    - the strict report status is pass
  covers:
    - specled.verify.finding_severity_overrides
```

## Verification

```yaml spec-verification
- kind: tagged_tests
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
    - specled.verify.command_output_via_tempfile
    - specled.verify.command_timeout_enforced
    - specled.verify.command_timeout_distinct_finding
    - specled.verify.command_timeout_cli_precedence
    - specled.verify.command_exit_code_recorded
- kind: tagged_tests
  execute: true
  covers:
    - specled.verify.requirement_without_test_tag
    - specled.verify.verification_cover_untagged
    - specled.verify.tag_scan_parse_error
    - specled.verify.tag_dynamic_value_skipped
    - specled.verify.tag_findings_respect_enforcement
    - specled.verify.tag_findings_suppressed_when_disabled
    - specled.verify.finding_severity_overrides
```
