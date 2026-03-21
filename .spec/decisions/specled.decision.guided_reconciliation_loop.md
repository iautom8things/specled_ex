---
id: specled.decision.guided_reconciliation_loop
status: accepted
date: 2026-03-20
affects:
  - repo.governance
  - spec.system
  - specled.package
  - specled.mix_tasks
  - specled.assist
  - specled.diffcheck
  - specled.reporting
---

# Guided Reconciliation Before Strict Enforcement

## Context

Spec Led Development needs a gentler local loop for small changes, brownfield work, and regression fixes, especially when a maintainer is still learning the workspace.

Strict drift enforcement alone catches missing co-changes, but it does not tell the maintainer what to do next.

## Decision

Add a read-only guided reconciliation step before strict enforcement.

Use `mix spec.assist` to inspect the current Git change set, point at the impacted subject or uncovered frontier, and suggest the next spec, proof, or ADR action.

Keep `.spec` authored and deterministic.

Use additive guidance in `mix spec.diffcheck` and frontier reporting in `mix spec.report`, but do not let those commands auto-edit current truth.

## Consequences

The default local loop becomes: make the change, tighten the proof, run `mix spec.assist`, update current truth, then run `mix spec.check`.

Brownfield adoption becomes easier because uncovered frontier files are reported explicitly instead of being left implicit.

Branch-local planning notes such as `docs/plans/*.md` are not treated as current-truth policy surfaces.
