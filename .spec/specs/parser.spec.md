# Parser

The parser reads authored `*.spec.md` files and extracts structured blocks.

## Intent

Parse Markdown spec files into a normalized map of metadata, requirements,
scenarios, verification targets, and exceptions. Record parse errors
without crashing so the verifier can report them.

```spec-meta
id: specled.parser
kind: module
status: active
summary: Extracts structured spec blocks from authored Markdown files.
surface:
  - lib/spec_led_ex/parser.ex
```

## Requirements

```spec-requirements
- id: specled.parser.standard_blocks
  statement: The parser shall extract spec-meta, spec-requirements, spec-scenarios, spec-verification, and spec-exceptions fenced blocks from a spec file.
  priority: must
  stability: stable
- id: specled.parser.title_extraction
  statement: The parser shall record the first Markdown H1 heading as the subject title.
  priority: should
  stability: stable
- id: specled.parser.resilient_errors
  statement: The parser shall continue parsing and collect parse errors when a block cannot be decoded or when spec-meta appears more than once.
  priority: must
  stability: stable
```

## Scenarios

```spec-scenarios
- id: specled.parser.malformed_json
  given:
    - a spec file with invalid JSON in a spec-meta block
  when:
    - the parser processes the file
  then:
    - the result includes a parse error
    - the parser does not crash
  covers:
    - specled.parser.resilient_errors
```

## Verification

```spec-verification
- kind: source_file
  target: lib/spec_led_ex/parser.ex
  covers:
    - specled.parser.standard_blocks
    - specled.parser.title_extraction
    - specled.parser.resilient_errors
- kind: test_file
  target: test/spec_led_ex_test.exs
  covers:
    - specled.parser.standard_blocks
```
