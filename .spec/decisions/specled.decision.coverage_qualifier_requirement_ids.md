---
id: specled.decision.coverage_qualifier_requirement_ids
status: accepted
date: 2026-07-25
affects:
  - specled.spec_review.coverage_observed_approximate_qualifier
  - specled.spec_review.coverage_file_level_proxy_qualifier
change_type: deprecates
reverses_what: >-
  The requirement identifiers that described per-test coverage as
  observed/approximate and as a file-level proxy are retired because the
  requirements now guarantee exact-up-to-escaped-processes line-to-MFA
  intersection. Their current contracts continue under identifiers that name
  those guarantees directly.
---

# Coverage Qualifier Requirement IDs Match Their Current Contracts

## Context

The per-test coverage implementation moved from race-bounded, file-level proxy
evidence to synchronous boundary windows and real line-to-MFA intersection.
The requirement statements were updated with that behavioral change, but two
requirement identifiers retained the superseded terminology and asserted the
opposite of their prose.

## Decision

Rename
`specled.spec_review.coverage_observed_approximate_qualifier` to
`specled.spec_review.coverage_exact_up_to_escaped_processes_qualifier`, and
rename `specled.spec_review.coverage_file_level_proxy_qualifier` to
`specled.spec_review.coverage_line_mfa_intersection_qualifier`.

Only the identifiers change. The requirement statements, scenarios, renderer
behavior, and test evidence retain their existing normative force.

## Consequences

Coverage evidence and review surfaces now reference identifiers whose names
match the guarantees they verify. Append-only governance reports the same-PR
self-authorization warning for the retired identifiers; that warning is
expected and remains non-blocking.
