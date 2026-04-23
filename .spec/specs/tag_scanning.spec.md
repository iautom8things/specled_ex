# Tag Scanning

AST-based extraction of `@tag spec:` annotations from ExUnit test files.

## Intent

Link requirements to the tests that cover them without running the test suite. Parse
every configured test file with `Code.string_to_quoted/2`, pattern-match the supported
tag shapes, and produce a `requirement_id → [tests]` map the index and verifier can
consume. Surface parse errors and dynamic tag values as findings so silent gaps do not
accumulate.

```yaml spec-meta
id: specled.tag_scanning
kind: module
status: active
summary: AST-based scanner that extracts tag spec values from ExUnit files without compiling them.
surface:
  - lib/specled_ex/tag_scanner.ex
  - test/specled_ex/tag_scanner_test.exs
realized_by:
  api_boundary:
    - "SpecLedEx.TagScanner.scan/2"
    - "SpecLedEx.TagScanner.scan_file/1"
  implementation:
    - "SpecLedEx.TagScanner.extract_spec_from_arg/1"
    - "SpecLedEx.TagScanner.resolve_spec_value/1"
    - "SpecLedEx.TagScanner.extract_module_tags/2"
    - "SpecLedEx.TagScanner.collect_moduletags/2"
decisions:
  - specled.decision.ast_tag_scanning
  - specled.decision.configurable_test_tag_enforcement
```

## Requirements

```yaml spec-requirements
- id: specled.tag_scanning.supported_forms
  statement: >-
    The tag scanner shall extract requirement ids from the four supported forms
    (`@tag spec` with a string, `@tag` with a keyword list containing a `spec`
    entry, `@tag spec` with a list of strings, and `@moduletag spec`) without
    compiling the test files.
  priority: must
  stability: evolving
- id: specled.tag_scanning.form_string_literal
  statement: >-
    The tag scanner shall extract a single requirement id from an
    `@tag spec, "<id>"` annotation carrying a string literal value and
    link it to the following test name.
  priority: must
  stability: evolving
- id: specled.tag_scanning.form_keyword_list
  statement: >-
    The tag scanner shall extract the `spec:` entry of a keyword-list
    `@tag [spec: "<id>", ...]` annotation and ignore every non-`spec`
    key in that keyword list.
  priority: must
  stability: evolving
- id: specled.tag_scanning.form_list_of_ids
  statement: >-
    The tag scanner shall extract every id from an `@tag spec` whose
    value is a list of string literals and link all of them to the
    following test name.
  priority: must
  stability: evolving
- id: specled.tag_scanning.scan_aggregates_results
  statement: >-
    SpecLedEx.TagScanner.scan/2 shall return an ok tuple carrying a tag_map of
    requirement id to list of test occurrences, a parse_errors list of
    file/reason entries, and a dynamic_entries list of annotations whose value
    could not be resolved to a literal, all aggregated across the input paths.
  priority: must
  stability: evolving
- id: specled.tag_scanning.parse_errors_surfaced
  statement: >-
    The tag scanner shall collect each unparseable file into the parse_errors
    list instead of silently skipping it, so the verifier can emit a
    tag_scan_parse_error finding.
  priority: must
  stability: evolving
- id: specled.tag_scanning.dynamic_values_reported
  statement: >-
    The tag scanner shall detect `@tag spec` annotations whose value is not a
    string or list literal and report them as a separate collection that the
    verifier can emit as tag_dynamic_value_skipped findings.
  priority: must
  stability: evolving
- id: specled.tag_scanning.moduletag_applies_to_all_tests
  statement: >-
    A `@moduletag spec` annotation shall attach its requirement id to every
    test defined in that module.
  priority: must
  stability: evolving
- id: specled.tag_scanning.ignored_non_spec_tags
  statement: >-
    The tag scanner shall ignore `@tag` annotations that do not carry a `spec`
    key.
  priority: must
  stability: evolving
- id: specled.tag_scanning.deduplicated_matches
  statement: >-
    The tag scanner shall deduplicate identical file and test_name entries
    under the same requirement id, so two `@tag spec` annotations with the
    same id on the same test count once.
  priority: should
  stability: evolving
```

## Scenarios

```yaml spec-scenarios
- id: specled.tag_scanning.scenario.extract_literal_string
  given:
    - a test file containing an `@tag spec` annotation with the string literal `auth.login` before a `test/2` definition
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - the returned tag list contains `auth.login` linked to that test name
  covers:
    - specled.tag_scanning.form_string_literal
- id: specled.tag_scanning.scenario.extract_keyword_list
  given:
    - a test file containing a keyword-list `@tag` annotation whose `spec` entry is `auth.logout` and whose `timeout` entry is 5_000
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - the returned tag list contains `auth.logout`
    - the `timeout` key is ignored
  covers:
    - specled.tag_scanning.form_keyword_list
- id: specled.tag_scanning.scenario.extract_list_of_ids
  given:
    - a test file containing an `@tag spec` annotation whose value is the list `[a.one, a.two]`
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - the returned tag list contains both `a.one` and `a.two` linked to the same test
  covers:
    - specled.tag_scanning.form_list_of_ids
- id: specled.tag_scanning.scenario.moduletag_attaches_to_every_test
  given:
    - a test file declaring a `@moduletag spec` annotation with id `domain.root` at the top
    - the module contains two `test/2` blocks
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - `domain.root` is linked to both test names
  covers:
    - specled.tag_scanning.moduletag_applies_to_all_tests
- id: specled.tag_scanning.scenario.non_literal_value_reported
  given:
    - a test file containing an `@tag spec` annotation whose value is a module attribute reference
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - the file is reported in the dynamic-value collection with its file path and line
    - no requirement id is added to the tag_map for that test
  covers:
    - specled.tag_scanning.dynamic_values_reported
- id: specled.tag_scanning.scenario.parse_error_captured
  given:
    - a test file that cannot be parsed as Elixir
  when:
    - SpecLedEx.TagScanner.scan/2 runs on a directory containing it
  then:
    - the parse_errors list contains an entry with that file path and a reason
    - scanning the remaining files still produces a tag_map
  covers:
    - specled.tag_scanning.parse_errors_surfaced
- id: specled.tag_scanning.scenario.non_spec_tag_ignored
  given:
    - a test file containing an `@tag` annotation whose value is the atom `:slow` and no `spec` key
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - the returned tag list is empty
  covers:
    - specled.tag_scanning.ignored_non_spec_tags
- id: specled.tag_scanning.scenario.duplicate_entries_deduplicated
  given:
    - a test file containing two identical `@tag spec` annotations with id `a.one` on the same test
  when:
    - SpecLedEx.TagScanner.scan_file/1 runs on that file
  then:
    - `a.one` appears exactly once in the returned list
  covers:
    - specled.tag_scanning.deduplicated_matches
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/tag_scanner_test.exs
  execute: true
  covers:
    - specled.tag_scanning.supported_forms
    - specled.tag_scanning.form_string_literal
    - specled.tag_scanning.form_keyword_list
    - specled.tag_scanning.form_list_of_ids
    - specled.tag_scanning.scan_aggregates_results
    - specled.tag_scanning.parse_errors_surfaced
    - specled.tag_scanning.dynamic_values_reported
    - specled.tag_scanning.moduletag_applies_to_all_tests
    - specled.tag_scanning.ignored_non_spec_tags
    - specled.tag_scanning.deduplicated_matches
```
