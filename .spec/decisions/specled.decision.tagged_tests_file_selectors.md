---
id: specled.decision.tagged_tests_file_selectors
status: accepted
date: 2026-05-08
affects:
  - specled.tagged_tests
  - specled.tag_scanning
  - specled.verification
change_type: refines
---

# Tagged Tests Shall Execute By Test File

## Context

`tagged_tests` verification originally built a merged command with one
`--only spec:<id>` filter per covered requirement id. That works when ExUnit sees
a scalar runtime tag such as `@tag spec: "a.one"`, but it does not select tests
whose runtime tag value is a list such as `@tag spec: ["a.one", "a.two"]`.

The scanner already understands list-valued tags and maps every listed id to the
same test. Keeping `--only spec:<id>` would therefore make scan-time linking and
execution-time selection disagree.

## Decision

Build merged `tagged_tests` commands from scanner-backed test files instead of
ExUnit `--only spec:<id>` filters. `SpecLedEx.TaggedTests.build_command/2`
emits each unique backing file for the requested cover ids and keeps `--include
integration` before those files.

## Consequences

- Scalar and list-valued `@tag spec` entries execute through the same path.
- `@moduletag spec` and `@describetag spec` entries can execute because the
  scanner maps inherited tags back to their containing test files.
- The merged command may no longer show each requirement id as a CLI filter, so
  attribution remains the verifier's responsibility rather than ExUnit's.
- The command may execute unrelated tests in the same backing files. That is an
  intentional tradeoff: it keeps list-valued tag support correct without relying
  on ExUnit's exact tag filtering semantics.
