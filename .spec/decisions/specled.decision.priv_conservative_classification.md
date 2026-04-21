---
id: specled.decision.priv_conservative_classification
status: accepted
date: 2026-04-21
affects:
  - specled.policy_files
  - specled.branch_guard
---

# `priv/` Defaults To `:lib`; Only `priv/plts/` Is `:generated`

## Context

Red-team 04a#h5 flagged "silent signal loss" as the worst failure mode of a
`PolicyFiles` module: mis-classifying a real source file as generated causes
co-change findings to silently vanish, which is the opposite of what the
guard is for. `priv/repo/migrations/*.exs`, `priv/static/*`, `priv/gettext/`,
and similar are behavior-carrying source — migrations change schema, static
assets change UX, gettext entries change strings. Defaulting all of `priv/`
to `:generated` would drop these from co-change enforcement.

User review (2026-04-21, question 3) confirmed the refiner's default:
conservative — `priv/` preserves current behavior (`:lib`); `priv/plts/` is
carved out because dialyzer PLT files are compile-cache, not source.

## Decision

`SpecLedEx.PolicyFiles.classify/1` classifies:

- `priv/plts/**` → `:generated`
- everything else under `priv/**` → `:lib`

No other `priv/` subdirectory receives `:generated` treatment in v1. Adding
one requires a spec update and a decision file — the default is
deliberately "keep the signal, pay the noise if any."

## Consequences

- Positive: migrations, static assets, gettext, and other `priv/` content
  participate in co-change enforcement. The previous guard behavior is
  preserved.
- Positive: `priv/plts/` (dialyzer cache) does not trigger spurious findings
  when it changes.
- Negative: users with project-specific `priv/` subdirectories that are
  genuinely generated (e.g., bundler output cached in `priv/`) will see
  noise until they extend PolicyFiles. Documented as an extension point,
  not an auto-classification.
- Negative: broader carve-outs (if any) must land as spec + decision
  updates. This is the right rate for a rule about what is and is not
  code.
