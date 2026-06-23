---
id: specled.decision.verification_runtime_config
status: accepted
date: 2026-06-23
affects:
  - specled.api_boundary
  - specled.config
  - specled.mix_tasks
  - specled.verification
  - specled.tagged_tests
change_type: refines
---

# Verification Runtime Settings Are Workspace Configuration

## Context

Command-backed verification can be both slow and noisy in brownfield projects.
The default 120 second timeout is too short for repositories whose
`tagged_tests` verification aggregates a large ExUnit suite, and strict local
gates need a workspace-level way to stage verifier findings from warning to
info while coverage, tags, and file-reference comments are backfilled.

These settings are runtime verification policy, not authored subject behavior.
Encoding them in `.spec/config.yml` lets each adopting repository tune the gate
without forking SpecLedEx or editing mix task code.

## Decision

`SpecLedEx.Config` parses a `verification` section with:

1. `command_timeout_ms` — a positive integer timeout used by command and
   aggregated `tagged_tests` execution.
2. `severities` — a finding-code map whose values are `off`, `info`,
   `warning`, or `error`.

`mix spec.check` and `mix spec.validate` load this section and pass it into the
verifier before strict status is computed. Verifier severity overrides are
applied to verifier findings only; `branch_guard.severities` and
`guardrails.severities` remain separate namespaces for branch-diff and
append-only governance.

Command execution records the supervised command process exit status directly.
It no longer relies on a second sidecar exit file written after the wrapped
command completes, so process termination and exit-code attribution have one
source of truth.

## Consequences

- Positive: Brownfield repositories can keep strict `mix spec.check` enabled
  while turning known verifier backfill work into visible info findings.
- Positive: Large aggregated `tagged_tests` commands can complete without
  changing SpecLedEx defaults for every project.
- Positive: Command failure reporting now uses the same process signal that
  unblocks the verifier wait loop, avoiding stale or missing sidecar exit
  files.
- Negative: There are now three severity maps. They intentionally live in
  distinct namespaces: `verification.severities`,
  `branch_guard.severities`, and `guardrails.severities`.
