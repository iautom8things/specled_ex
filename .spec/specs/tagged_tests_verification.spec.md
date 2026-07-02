# Tagged Tests Verification

Aggregated `mix test` execution for `kind: tagged_tests` verifications.

## Intent

Make `@tag spec:`-backed coverage the preferred verification form by removing
per-spec `mix test` overhead. When a subject declares
`kind: tagged_tests` with an `execute: true` entry, the verifier collects
every such entry across the workspace, deduplicates the covered requirement
ids, looks up the backing test files in the test-tag index, and runs a single
`mix test --include integration <test_files>` command. The result is attributed
back to each participating verification slot so per-subject findings and
strength calculations stay independent.

```yaml spec-meta
id: specled.tagged_tests
kind: module
status: active
summary: Workspace-wide aggregation of tagged_tests verifications into a single mix test invocation.
surface:
  - lib/specled_ex/tagged_tests.ex
  - lib/specled_ex/tagged_tests/formatter.ex
  - lib/specled_ex/tagged_tests/attribution.ex
  - test/specled_ex/tagged_tests_test.exs
  - test/specled_ex/tagged_tests/formatter_test.exs
  - test/specled_ex/tagged_tests/attribution_test.exs
  - test/specled_ex/verifier_test.exs
  - test/integration/tagged_tests_attribution_test.exs
  - priv/helper_scripts/tag_tests_from_specs.exs
  - priv/helper_scripts/flip_command_to_tagged_tests.exs
realized_by:
  implementation:
    - "SpecLedEx.TaggedTests.collect_entries/1"
    - "SpecLedEx.TaggedTests.build_command/2"
    - "SpecLedEx.TaggedTests.Formatter"
    - "SpecLedEx.TaggedTests.Attribution.read_artifact/1"
    - "SpecLedEx.TaggedTests.Attribution.attribute/2"
decisions:
  - specled.decision.tagged_tests_file_selectors
  - specled.decision.verification_runtime_config
  - specled.decision.evidence_based_attribution
```

## Requirements

```yaml spec-requirements
- id: specled.tagged_tests.collect_entries
  statement: >-
    SpecLedEx.TaggedTests.collect_entries/1 shall return one entry per
    executable `kind: tagged_tests` verification across the provided
    subjects, carrying the subject-scoped verification key and the list
    of cover ids. Non-executable entries and other kinds shall be
    excluded.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command
  statement: >-
    SpecLedEx.TaggedTests.build_command/2 shall combine the given cover
    ids into a single `mix test` command line that appends the unique set of
    backing test files drawn from the tag entries. It shall drop ids with
    no tag entry and return `:no_tests` when none of the ids are backed.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_combines_backed_ids
  statement: >-
    build_command/2 shall, when given cover ids all backed by the tag
    map, produce a single `mix test` command line that begins with `mix test`
    and appends each unique backing test file exactly once.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_drops_unbacked_ids
  statement: >-
    build_command/2 shall omit any cover id not backed by the tag map
    from the emitted command, while still emitting test files for the
    backed ids.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_no_tests_when_all_unbacked
  statement: >-
    build_command/2 shall return the atom `:no_tests` when none of the
    requested cover ids have an entry in the tag map, so the caller can
    short-circuit execution without building an empty command.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_includes_integration_flag
  statement: >-
    build_command/2 shall append `--include integration` to every emitted
    command so host projects that configure `ExUnit.configure(exclude:
    :integration)` still execute integration-tagged tests participating in a
    merged run. The flag is appended after `mix test` and before the test
    file arguments.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_file_selectors_for_list_tags
  statement: >-
    build_command/2 shall use scanner-backed test files instead of ExUnit
    `--only spec:<id>` filters, so tests whose runtime `:spec` tag value is a
    list still execute when any listed cover id is requested.
  priority: must
  stability: evolving
- id: specled.tagged_tests.merged_run_attribution
  statement: >-
    When verification runs with command execution enabled, the verifier
    shall invoke the aggregated `mix test` command at most once per report.
    When the streaming attribution artifact is readable, it shall distribute
    the per-cover-id outcomes observed at runtime to each participating
    tagged_tests verification. When the artifact is absent or unreadable, it
    shall distribute the single shared run outcome (exit code and output) to
    every participating verification, preserving the prior shared-fate
    behavior.
  priority: must
  stability: evolving
- id: specled.tagged_tests.shared_run_finding_context
  statement: >-
    Findings emitted from an aggregated tagged_tests command result shall
    state that one command was shared by the participating entry count and
    that the finding reflects the shared run rather than a subject-specific
    failure, while preserving distribution of the single result to every
    participating verification entry.
  priority: must
  stability: evolving
- id: specled.tagged_tests.strength_progression
  statement: >-
    A `tagged_tests` claim shall reach `linked` strength when its cover
    id has at least one entry in the tag map and `executed` strength when the
    merged run yields positive evidence for that cover id — a recorded passing
    test with no recorded failure when the attribution artifact is present, or
    an aggregated exit-zero run when the artifact is absent. Untagged covers
    shall remain at `claimed` strength.
  priority: must
  stability: evolving
- id: specled.tagged_tests.strength_executed_on_green_run
  statement: >-
    A `tagged_tests` claim whose cover ids are all backed by the tag map shall
    be reported at `executed` strength when the merged run records a passing
    test for the cover id (attribution artifact present) or exits zero
    (artifact absent). When the artifact is present, a cover id with no
    recorded execution shall remain at `linked` strength even if the
    aggregated run exits zero.
  priority: must
  stability: evolving
- id: specled.tagged_tests.build_command_appends_formatters
  statement: >-
    build_command/2 shall append `--formatter SpecLedEx.TaggedTests.Formatter`
    and `--formatter ExUnit.CLIFormatter` to every emitted command, after the
    `--include integration` flag and before the test file arguments, so the
    merged run streams a per-test evidence artifact while retaining ExUnit's
    default console output.
  priority: must
  stability: evolving
- id: specled.tagged_tests.formatter_streams_jsonl
  statement: >-
    SpecLedEx.TaggedTests.Formatter shall append one line-flushed JSONL event
    to the artifact path for each `test_started` and `test_finished` cast of a
    test carrying a `:spec` tag (string or list, normalized to a list) and one
    `suite_finished` event when the suite ends. Each `test_finished` event
    shall record the test state as one of `pass`, `failed`, `invalid`,
    `skipped`, or `excluded`. Tests without a `:spec` tag shall not be
    recorded.
  priority: must
  stability: evolving
- id: specled.tagged_tests.formatter_noop_without_artifact_path
  statement: >-
    SpecLedEx.TaggedTests.Formatter shall be disabled when no artifact path is
    configured (the `SPECLED_ATTRIBUTION_PATH` env var is unset or blank and no
    `:artifact_path` init option is given); every event handler shall no-op and
    write nothing.
  priority: must
  stability: evolving
- id: specled.tagged_tests.attribution_partial_outcomes
  statement: >-
    SpecLedEx.TaggedTests.Attribution.attribute/2 shall classify each cover id
    from the recorded events as `:passed` (a recorded pass with no recorded
    failure), `{:failed, tests}` (any recorded failed or invalid test),
    `{:in_flight, tests}` (started but never finished — a set, since the run
    may execute with `max_cases > 1`), `:not_started` (no recorded events and
    no `suite_finished`), or `:not_executed` (no pass/fail evidence but
    `suite_finished` present, including skipped/excluded-only). An event shall
    match a cover id when the event's `spec` list contains the id or when the
    event's `{file, line}` is among the scanner-supplied locations passed for
    that cover id, so a cover whose runtime `:spec` tag was collapsed by ExUnit
    is still credited by the test the scanner mapped to it. read_artifact/1
    shall return `{:ok, events}` for a readable artifact file (events may be
    empty; a trailing partial line is tolerated) and `:absent` only when the
    file is missing or unreadable.
  priority: must
  stability: evolving
- id: specled.tagged_tests.attribution_degrades_to_shared_fate
  statement: >-
    When the attribution artifact is absent or unreadable, the verifier shall
    reproduce the prior shared-fate behavior exactly: every participating
    claim receives the aggregated run's exit code, `executed` means aggregated
    exit zero, and per-subject findings carry the shared-run context. No
    per-cover attribution is attached in this case.
  priority: must
  stability: evolving
- id: specled.tagged_tests.cover_not_executed_finding
  statement: >-
    When the attribution artifact is present and a completed merged run
    (`suite_finished` observed) records no passing or failing test for a cover
    id — because it was skipped, excluded, or filtered out — the verifier shall
    emit a `tagged_tests_cover_not_executed` warning naming the cover id, and
    the claim shall stay at `linked` strength rather than `executed`.
  priority: must
  stability: evolving
- id: specled.tagged_tests.timeout_names_hang_suspects
  statement: >-
    When the merged run times out with a readable attribution artifact, the
    `verification_command_timeout` finding shall name any started-but-unfinished
    tests as hang suspects and count the cover ids that never started (the
    timeout remainder). When the artifact recorded no events, the finding shall
    state that the run timed out before any test started (likely compile cost).
  priority: must
  stability: evolving
- id: specled.tagged_tests.strength_claimed_on_untagged_cover
  statement: >-
    A `tagged_tests` claim whose cover id has no entry in the tag map
    shall remain at `claimed` strength, independent of any aggregated
    run outcome.
  priority: must
  stability: evolving
- id: specled.tagged_tests.missing_tag_finding
  statement: >-
    The verifier shall emit a `tagged_tests_cover_missing_tag` warning
    for every cover id declared on a `tagged_tests` verification that
    has no entry in the tag map, so silent gaps between specs and
    tagged tests surface during spec.check.
  priority: must
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.tagged_tests.scenario.collect_entries_filters_kinds
  given:
    - "a subject with one `kind: tagged_tests` verification flagged execute=true"
    - "a second subject mixing `kind: command` and non-executable `kind: tagged_tests` entries"
  when:
    - SpecLedEx.TaggedTests.collect_entries/1 is called with both subjects
  then:
    - exactly the executable tagged_tests entries are returned
    - each entry carries the subject-scoped verification key and the declared cover ids
  covers:
    - specled.tagged_tests.collect_entries
- id: specled.tagged_tests.scenario.build_command_combines_ids_and_files
  given:
    - a tag map with entries for ids `a.one`, `a.two`, and `b.one` across two test files
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called with all three ids
  then:
    - the returned command begins with `mix test`
    - it appends each unique test file exactly once
  covers:
    - specled.tagged_tests.build_command_combines_backed_ids
- id: specled.tagged_tests.scenario.build_command_drops_unmapped_ids
  given:
    - a tag map that contains entries for `a.one` only
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called with `[a.one, missing.id]`
  then:
    - the returned command includes the backing test file for `a.one`
    - the returned command does not reference `missing.id`
  covers:
    - specled.tagged_tests.build_command_drops_unbacked_ids
- id: specled.tagged_tests.scenario.build_command_no_tests_when_all_unmapped
  given:
    - a tag map with no entries for the requested cover ids
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called
  then:
    - the function returns `:no_tests`
  covers:
    - specled.tagged_tests.build_command_no_tests_when_all_unbacked
- id: specled.tagged_tests.scenario.build_command_appends_include_integration
  given:
    - a tag map with one backed cover id and a single test file
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called
  then:
    - the returned command contains `--include integration`
    - the `--include integration` flag appears after `mix test` and before the test file
  covers:
    - specled.tagged_tests.build_command_includes_integration_flag
- id: specled.tagged_tests.scenario.build_command_executes_list_tagged_test
  given:
    - a tag map entry created from a test whose `@tag spec` value is `[a.one, a.two]`
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called for `a.two`
  then:
    - the returned command uses the backing test file instead of `--only spec:a.two`
    - running the returned command executes the list-tagged test
  covers:
    - specled.tagged_tests.build_command_file_selectors_for_list_tags
- id: specled.tagged_tests.scenario.merged_run_executes_once_across_subjects
  given:
    - "two subjects each declaring a `kind: tagged_tests` verification with execute=true"
    - a tag map backing every cover id to a test file
    - a shim `mix` executable on PATH that records each invocation
  when:
    - verification runs with run_commands=true
  then:
    - the shim is invoked exactly once
    - the recorded command includes every expected test file and no `--only spec:<id>` filters
    - both claims reach `executed` strength
  covers:
    - specled.tagged_tests.merged_run_attribution
    - specled.tagged_tests.strength_executed_on_green_run
- id: specled.tagged_tests.scenario.shared_run_finding_context
  given:
    - "two subjects each declaring a `kind: tagged_tests` verification with execute=true"
    - a tag map backing every cover id to a test file
    - the aggregated command fails or times out
  when:
    - verification distributes the aggregated command result back to each entry
  then:
    - every per-subject command failure or timeout finding includes the participating entry count
    - every per-subject finding states that the finding reflects the shared run, not a subject-specific failure
  covers:
    - specled.tagged_tests.shared_run_finding_context
- id: specled.tagged_tests.scenario.missing_tag_warning_emitted
  given:
    - "a subject with a `kind: tagged_tests` verification covering `req.untagged`"
    - an empty tag map
  when:
    - verification runs
  then:
    - a `tagged_tests_cover_missing_tag` warning references `req.untagged`
    - the corresponding claim stays at `claimed` strength
  covers:
    - specled.tagged_tests.missing_tag_finding
    - specled.tagged_tests.strength_claimed_on_untagged_cover
- id: specled.tagged_tests.scenario.build_command_appends_formatter_flags
  given:
    - a tag map with one backed cover id and a single test file
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called
  then:
    - the command contains `--formatter SpecLedEx.TaggedTests.Formatter` and `--formatter ExUnit.CLIFormatter`
    - both formatter flags appear after `--include integration` and before the test file
  covers:
    - specled.tagged_tests.build_command_appends_formatters
- id: specled.tagged_tests.scenario.formatter_streams_spec_tagged_events
  given:
    - the formatter initialized with an artifact path
    - a spec-tagged test and an untagged sibling
  when:
    - the formatter receives test_started, test_finished, and suite_finished casts
  then:
    - one JSONL event is appended per lifecycle cast of the spec-tagged test
    - the test_finished event records a `state` and the untagged test is never recorded
  covers:
    - specled.tagged_tests.formatter_streams_jsonl
- id: specled.tagged_tests.scenario.formatter_noops_without_path
  given:
    - the formatter initialized with no artifact path
  when:
    - the formatter receives lifecycle casts
  then:
    - init returns the `:disabled` state
    - every handler no-ops and writes nothing
  covers:
    - specled.tagged_tests.formatter_noop_without_artifact_path
- id: specled.tagged_tests.scenario.attribution_classifies_partial_outcomes
  given:
    - a recorded event stream mixing passed, failed, started-only, and silent covers
  when:
    - SpecLedEx.TaggedTests.Attribution.attribute/2 is called with the cover ids
  then:
    - passing covers map to `:passed` and failing covers to `{:failed, tests}`
    - started-but-unfinished covers map to a `{:in_flight, tests}` set and silent covers discriminate on `suite_finished`
  covers:
    - specled.tagged_tests.attribution_partial_outcomes
- id: specled.tagged_tests.scenario.attribution_degrades_to_shared_fate
  given:
    - "two subjects each declaring a `kind: tagged_tests` verification with execute=true"
    - a merged run whose command writes no attribution artifact and exits non-zero
  when:
    - verification runs with run_commands=true
  then:
    - every participating subject receives a shared `verification_command_failed` finding with shared-run context
    - both claims stay at `linked` strength, identical to the pre-attribution behavior
  covers:
    - specled.tagged_tests.attribution_degrades_to_shared_fate
- id: specled.tagged_tests.scenario.cover_not_executed_warns_and_stays_linked
  given:
    - a completed merged run (`suite_finished` recorded) whose artifact records a pass for one cover and nothing for another
  when:
    - verification distributes the attribution to each entry
  then:
    - the executed cover reaches `executed` strength
    - the silent cover receives a `tagged_tests_cover_not_executed` warning and stays at `linked`
  covers:
    - specled.tagged_tests.cover_not_executed_finding
- id: specled.tagged_tests.scenario.timeout_names_hang_suspects
  given:
    - a merged run that records a started-but-unfinished test then times out
  when:
    - verification distributes the attribution to each entry
  then:
    - the timeout finding names the started-but-unfinished test as a hang suspect
    - the timeout finding counts the cover ids that never started, and an empty artifact reports a likely compile cost
  covers:
    - specled.tagged_tests.timeout_names_hang_suspects
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.tagged_tests.collect_entries
    - specled.tagged_tests.build_command
    - specled.tagged_tests.build_command_combines_backed_ids
    - specled.tagged_tests.build_command_drops_unbacked_ids
    - specled.tagged_tests.build_command_no_tests_when_all_unbacked
    - specled.tagged_tests.build_command_includes_integration_flag
    - specled.tagged_tests.build_command_file_selectors_for_list_tags
    - specled.tagged_tests.merged_run_attribution
    - specled.tagged_tests.shared_run_finding_context
    - specled.tagged_tests.strength_progression
    - specled.tagged_tests.strength_executed_on_green_run
    - specled.tagged_tests.strength_claimed_on_untagged_cover
    - specled.tagged_tests.missing_tag_finding
    - specled.tagged_tests.build_command_appends_formatters
    - specled.tagged_tests.formatter_streams_jsonl
    - specled.tagged_tests.formatter_noop_without_artifact_path
    - specled.tagged_tests.attribution_partial_outcomes
    - specled.tagged_tests.attribution_degrades_to_shared_fate
    - specled.tagged_tests.cover_not_executed_finding
    - specled.tagged_tests.timeout_names_hang_suspects
```
