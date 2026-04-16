---
id: specled.decision.configurable_test_tag_enforcement
status: accepted
date: 2026-04-16
affects:
  - specled.config
  - specled.index_state
  - specled.verification
  - specled.decisions
  - specled.branch_guard
  - specled.mix_tasks
  - specled.tag_scanning
---

# Test-Tag Enforcement Shall Be Opt-In And Configurable Per-Workspace

## Context

Tag scanning adds a new verification lane: every `must` requirement should have at
least one `@tag spec: "<id>"` annotation in the test suite. Enforcing this as a
hard error out of the box would:

- Break every existing specled_ex adopter on the day they upgrade.
- Force workspaces that cannot or do not want to annotate tests (e.g. early-stage
  projects, integration test suites in other repos) to carry noise.
- Couple spec co-change severity to a separate dimension (test-annotation coverage),
  conflating two concerns that evolve at different rates.

At the same time, teams that do adopt tagging want a hard gate to prevent
coverage regressions.

## Decision

Make test-tag scanning opt-in and its findings configurable via `.spec/config.yml`:

```yaml
test_tags:
  enabled: false           # default — scanning is off
  paths: ["test"]          # directories the scanner walks when enabled
  enforcement: warning     # warning | error — severity of tag findings
```

- When `enabled: false` (default), the index has no `test_tags` key, and the
  verifier and branch guard emit no tag-related findings.
- When `enabled: true`, the index gains a `test_tags` map and tag findings are
  produced at the severity declared by `enforcement`. `warning` leaves
  `mix spec.check` exit status unchanged; `error` fails the gate.
- CLI flags `--test-tags` and `--no-test-tags` override the config for a single
  invocation. Precedence is CLI flag > `.spec/config.yml` > built-in default.
- Unknown `enforcement` values fall back to the default and emit a
  `Logger.warning` so the misconfiguration is visible.

## Consequences

- Existing adopters upgrade with no behavior change until they explicitly opt in.
- Teams can graduate from `enforcement: warning` to `enforcement: error` when
  coverage reaches 100%, giving a real adoption ramp.
- The config file is now load-bearing: it gains semantic weight beyond its
  initial three fields. A missing or malformed file degrades to defaults so
  this never becomes a hard failure at spec-check time.
- CI can override the workspace default (`mix spec.check --test-tags`) to
  enforce higher severity in pipelines while keeping local runs quieter.
