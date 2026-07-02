---
id: specled.decision.realization_tiers_nil_default
status: accepted
date: 2026-07-01
affects:
  - specled.config
  - specled.branch_guard
  - specled.implementation_tier
change_type: extends
---

# realization.enabled_tiers: Nil Means Orchestrator Default, Unknown Tiers Fail Loud

## Context

`SpecLedEx.Config.Realization` shipped as a v1 placeholder: `defstruct
enabled_tiers: [:api_boundary]` with a `parse/1` that has zero callers.
Meanwhile `SpecLedEx.BranchCheck.run_realization/3` calls
`Orchestrator.run_with_attestations/2` without `:enabled_tiers`, so the
orchestrator's `@default_tiers` (`[:api_boundary, :expanded_behavior,
:typespecs, :use]`) always applies. A `realization:` section in
`.spec/config.yml` parses to nowhere and silently does nothing — a consumer
cannot enable the `:implementation` tier at all.

Wiring the config in forces two semantic choices:

1. What does an *absent* `realization:` section mean? The placeholder struct
   default (`[:api_boundary]`) and the orchestrator default disagree; adopting
   the struct default would silently shrink the tier set for every existing
   workspace.
2. What happens to *unknown* tier names? `parse/1` already rejects them with
   diagnostics; dropping those on the floor recreates the silent-no-op bug
   this change exists to fix.

## Decision

**Nil means default.** `Config.Realization` becomes `defstruct enabled_tiers:
nil, rejected: []`. The struct records what the user wrote: `nil` = "said
nothing". `BranchCheck.run_realization/3` omits the `:enabled_tiers` opt when
the value is `nil`, so the orchestrator's `@default_tiers` remains the single
owned default (`Orchestrator.default_tiers/0` stays the public accessor).
The config layer never hardcodes a tier list, so two default lists can never
drift apart and `Config` gains no dependency on the realization orchestrator.

**Explicit empty list is an opt-out.** The placeholder's `[] ->
[:api_boundary]` coercion is removed: `enabled_tiers: []` runs zero
realization tiers. (No existing callers, so no migration.)

**Unknown tier names fail loud, twice.** `parse/1` keeps returning diagnostic
strings (surfaced as `config_warning` diagnostics by `Config.build/1`) and
additionally records raw rejected tokens on the `rejected:` field. The branch
check emits one `branch_guard_realization_unknown_tier` finding per rejected
token (default severity `warning`, overridable/`off` via
`branch_guard.severities`). Because `BranchCheck.run/3` fails on any finding
regardless of severity, a typo'd tier name fails `mix spec.check` until fixed
or explicitly silenced.

## Consequences

- Absent config preserves the exact pre-change tier set — upgrading adopters
  see no behavior change until they write a `realization:` section.
- Atlas (motivating consumer) can set `realization: enabled_tiers:
  [api_boundary, implementation]` and the implementation tier actually runs.
- A misspelled tier is a gate failure, not a silently-missing tier — the
  failure mode that motivated this change cannot recur. Teams that want the
  old leniency set `branch_guard_realization_unknown_tier: off`.
- `enabled_tiers: []` is now meaningful; the implementation must ensure the
  empty-tier path cannot clobber committed realization hashes.
- The config struct stays a pure record of user input; default-tier ownership
  lives only in the orchestrator.
