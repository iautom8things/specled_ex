# Parser

The parser reads authored `*.spec.md` files and extracts structured blocks.

## Intent

Parse Markdown spec files into a normalized map of metadata, requirements,
scenarios, verification targets, and exceptions. Record parse errors
without crashing so the verifier can report them.

```yaml spec-meta
id: specled.parser
kind: module
status: active
summary: Extracts structured spec blocks from authored Markdown files.
surface:
  - lib/specled_ex/parser.ex
```

## Requirements

```yaml spec-requirements
- id: specled.parser.standard_blocks
  statement: The parser shall extract spec-meta, spec-requirements, spec-scenarios, spec-verification, and spec-exceptions fenced blocks from a spec file.
  priority: must
  stability: stable
- id: specled.parser.title_extraction
  statement: The parser shall record the first Markdown H1 heading as the subject title.
  priority: should
  stability: stable
- id: specled.parser.resilient_errors
  statement: The parser shall continue parsing and collect parse errors when a block cannot be decoded, when a structured block appears more than once, or when block items fail schema validation.
  priority: must
  stability: stable
- id: specled.parser.resilient_on_decode_error
  statement: The parser shall record a parse error and continue (not crash) when a structured block contains malformed YAML/JSON that cannot be decoded.
  priority: must
  stability: stable
- id: specled.parser.resilient_on_duplicate_block
  statement: The parser shall record a duplicate-block parse error and continue (not crash) when the same structured block kind appears more than once in a single spec file.
  priority: must
  stability: stable
- id: specled.parser.info_string_tokens
  statement: The parser shall recognize a spec block when any whitespace-separated token of the opening fence info string matches a spec-* tag, so authors can prefix or suffix a syntax-highlight language such as `yaml` without losing parser recognition.
  priority: must
  stability: stable
```

## Scenarios

```yaml spec-scenarios
- id: specled.parser.malformed_json
  given:
    - a spec file with invalid JSON in a spec-meta block
  when:
    - the parser processes the file
  then:
    - the result includes a parse error
    - the parser does not crash
  covers:
    - specled.parser.resilient_on_decode_error
- id: specled.parser.duplicate_empty_block
  given:
    - a spec file with two empty spec-requirements blocks
  when:
    - the parser processes the file
  then:
    - the result includes a duplicate-block parse error
    - the parser does not crash
  covers:
    - specled.parser.resilient_on_duplicate_block
- id: specled.parser.resilient_errors_totality
  given:
    - a spec file containing a structured block that cannot be decoded, and elsewhere a duplicated structured block
  when:
    - the parser processes the file
  then:
    - the result includes parse errors for both failure modes
    - the parser does not crash and continues to extract well-formed blocks
  covers:
    - specled.parser.resilient_errors
- id: specled.parser.language_tagged_fence
  given:
    - a spec file whose opening fences are written as `yaml spec-meta` and `yaml spec-requirements`
  when:
    - the parser processes the file
  then:
    - the spec-meta and spec-requirements blocks are extracted as if the fences were bare
    - no parse errors are recorded
  covers:
    - specled.parser.info_string_tokens
    - specled.parser.standard_blocks
```

## Verification

```yaml spec-verification
- kind: command
  target: mix test test/specled_ex/parser_test.exs
  execute: true
  covers:
    - specled.parser.standard_blocks
    - specled.parser.title_extraction
    - specled.parser.resilient_errors
    - specled.parser.resilient_on_decode_error
    - specled.parser.resilient_on_duplicate_block
    - specled.parser.info_string_tokens
```
