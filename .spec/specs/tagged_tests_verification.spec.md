# Tagged Tests Verification

Aggregated `mix test` execution for `kind: tagged_tests` verifications.

## Intent

Make `@tag spec:`-backed coverage the preferred verification form by removing
per-spec `mix test` overhead. When a subject declares
`kind: tagged_tests` with an `execute: true` entry, the verifier collects
every such entry across the workspace, deduplicates the covered requirement
ids, looks up the backing test files in the test-tag index, and runs a single
`mix test --only spec:<id>... <test_files>` command. The result is attributed
back to each participating verification slot so per-subject findings and
strength calculations stay independent.

```yaml spec-meta
id: specled.tagged_tests
kind: module
status: active
summary: Workspace-wide aggregation of tagged_tests verifications into a single mix test invocation.
surface:
  - lib/specled_ex/tagged_tests.ex
  - test/specled_ex/tagged_tests_test.exs
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
    ids into a single `mix test` command line that accumulates one
    `--only spec:<id>` flag per id backed by the tag map and appends the
    unique set of test files drawn from the tag entries. It shall drop
    ids with no tag entry and return `:no_tests` when none of the ids
    are backed.
  priority: must
  stability: evolving
- id: specled.tagged_tests.merged_run_attribution
  statement: >-
    When verification runs with command execution enabled, the verifier
    shall invoke the aggregated `mix test` command at most once per
    report and distribute its exit code and output to every
    participating tagged_tests verification so each claim receives the
    same execution outcome.
  priority: must
  stability: evolving
- id: specled.tagged_tests.strength_progression
  statement: >-
    A `tagged_tests` claim shall reach `linked` strength when its cover
    id has at least one entry in the tag map and `executed` strength
    when the aggregated run also exits zero. Untagged covers shall
    remain at `claimed` strength.
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
    - it includes one `--only spec:<id>` flag per id
    - it appends each unique test file exactly once
  covers:
    - specled.tagged_tests.build_command
- id: specled.tagged_tests.scenario.build_command_drops_unmapped_ids
  given:
    - a tag map that contains entries for `a.one` only
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called with `[a.one, missing.id]`
  then:
    - the returned command includes `--only spec:a.one` and the backing file
    - the returned command does not reference `missing.id`
  covers:
    - specled.tagged_tests.build_command
- id: specled.tagged_tests.scenario.build_command_no_tests_when_all_unmapped
  given:
    - a tag map with no entries for the requested cover ids
  when:
    - SpecLedEx.TaggedTests.build_command/2 is called
  then:
    - the function returns `:no_tests`
  covers:
    - specled.tagged_tests.build_command
- id: specled.tagged_tests.scenario.merged_run_executes_once_across_subjects
  given:
    - "two subjects each declaring a `kind: tagged_tests` verification with execute=true"
    - a tag map backing every cover id to a test file
    - a shim `mix` executable on PATH that records each invocation
  when:
    - verification runs with run_commands=true
  then:
    - the shim is invoked exactly once
    - "the recorded command includes every expected `--only spec:<id>` flag and test file"
    - both claims reach `executed` strength
  covers:
    - specled.tagged_tests.merged_run_attribution
    - specled.tagged_tests.strength_progression
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
    - specled.tagged_tests.strength_progression
```

## Verification

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - specled.tagged_tests.collect_entries
    - specled.tagged_tests.build_command
    - specled.tagged_tests.merged_run_attribution
    - specled.tagged_tests.strength_progression
    - specled.tagged_tests.missing_tag_finding
```
