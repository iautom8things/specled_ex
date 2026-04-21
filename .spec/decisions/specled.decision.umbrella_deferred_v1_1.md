---
id: specled.decision.umbrella_deferred_v1_1
status: accepted
date: 2026-04-21
affects:
  - specled.api_boundary
  - specled.implementation_tier
  - specled.expanded_behavior_tier
  - specled.use_tier
  - specled.triangulation
---

# Umbrella Apps Are Not Supported In v1; Detectors Emit `detector_unavailable`

## Context

Red-team 04a#m6 flagged that an umbrella project has one `mix.exs` per app,
one `_build/` per app, independent compile manifests, and its own dependency
graph between sibling apps. Every realization orchestrator assumes a single
project root. Making them umbrella-aware touches: `Context.load/1` (must
enumerate apps), Manifest reading (one manifest per app), Xref (cross-app
edges), tracer ETF path (per-app), and HashStore (namespaced by app). The
spec already identifies "multiple subsystem" support as a large scope item;
umbrella would push v1 past a reasonable cut line.

Graceful degradation is the standard specled pattern (e.g.,
`:no_coverage_artifact`, `:debug_info_stripped`): detect, emit a visible
no-op finding, and decline to guess.

## Decision

- Each tier-2+ orchestrator (`api_boundary`, `implementation`, 
  `expanded_behavior`, `typespecs`, `use`) and `CoverageTriangulation` calls
  `Mix.Project.umbrella?/0` at entry. If true, each emits a single
  `detector_unavailable` finding with reason `:umbrella_unsupported` and
  returns without attempting analysis.
- `mix spec.check` exit status respects severity configuration for the
  `detector_unavailable` code; by default it is `:info`, so umbrella users
  see a clear notice but the gate does not fail.
- Tier-1 (`severity`, `policy_files`, `prose_guard`, `spec_drift_trailer`)
  does not involve compile manifests and works on umbrella projects
  unchanged.
- v1.1 will add umbrella support. No v1 code paths attempt partial umbrella
  analysis.

## Consequences

- Positive: umbrella users are not silently misled by partial or incorrect
  analysis.
- Positive: v1 ships on time with a clear deferral signal.
- Negative: umbrella users get less value from v1 than standard-project
  users. The CHANGELOG and README explicitly state v1 scope excludes
  umbrellas.
- Negative: when v1.1 lands umbrella support, the manifest/state.json schema
  for those users will expand. Upgrade path is documented at that time.
