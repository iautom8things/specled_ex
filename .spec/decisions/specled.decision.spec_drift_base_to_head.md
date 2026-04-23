---
id: specled.decision.spec_drift_base_to_head
status: accepted
date: 2026-04-21
affects:
  - specled.spec_drift_trailer
  - specled.branch_guard
change_type: clarifies
---

# `Spec-Drift:` Trailers Are Scanned Across `base..HEAD`, Not HEAD Only

## Context

Red-team 04a#h7 flagged that the initial design scanned only the HEAD commit
message for `Spec-Drift:` trailers. This is wrong for any CI configuration
where the PR is evaluated as a squash or merge commit — the trailer was on
an earlier commit and HEAD is an auto-generated merge message without it.
Local `mix spec.check` runs after branch work and also sees multiple commits,
so HEAD-only reading drops user intent silently.

User review (2026-04-21, question 1) confirmed: "if any commit in the PR
range carries `Spec-Drift: refactor`, the trailer applies to the whole
range's findings for that PR." Per-commit semantics were offered as an
alternative; the user explicitly chose per-branch.

## Decision

`SpecLedEx.BranchCheck.Trailer.read/2` shells `git log <base>..HEAD
--format=%B` and returns the union of parsed trailer overrides across every
commit in the range. `<base>` is resolved the same way the rest of
`BranchCheck` resolves it: the `--base` CLI flag, else the merge-base with
`main`.

HEAD-only scanning is not a supported mode and the option is not exposed.

## Consequences

- Positive: user intent survives squashes, merge commits, and multi-commit
  branches.
- Positive: matches the `guidance_scope.ref` window that existing
  `ChangeAnalysis` uses — one window concept across the workflow.
- Negative: a `Spec-Drift: <code>=<severity>` declared early in the branch
  cannot be "taken back" by a later commit. If the user needs per-commit
  granularity (rare), they must rewrite history. This is documented in the
  module.
- Negative: `git log` shell-out is I/O per check. Cost is negligible (single
  process, small range).
