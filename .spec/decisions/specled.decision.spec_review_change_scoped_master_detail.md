---
id: specled.decision.spec_review_change_scoped_master_detail
status: accepted
date: 2026-07-03
affects:
  - specled.spec_review
change_type: refines
---

# Spec Review v2: Change-Scoped Master–Detail Layout

## Context

The v1 layout rendered triage as a top-of-page hero (partial-report banner,
"Out of sync" headline, five-node triangle diagram, thirteen-row checklist,
flat findings list) followed by every affected subject as a fully-expanded
card in one scroll. On a real 57-file / 42-subject change set this produced a
5.3 MB page where the reviewer met three screens of verification machinery
before the first subject, and 23 visually identical `no_realized_by` rows
that read as alarm despite zero failed checks.

Reviewing that artifact surfaced two structural defects:

1. **Scope mixing.** The verifier runs over the whole repo at head, so
   whole-repo state (requirement/binding counts, strength inventories,
   triangle leg states, pre-existing findings) rendered interleaved with
   change-scoped information (the diff, spec edits, changed decisions). A
   reviewer cannot tell "what did this PR do" from "what is the standing
   state of the spec system" — and the standing state would look identical
   on any PR cut from the same commit. Findings were the sharpest case:
   pre-existing debt on touched subjects presented as if the PR caused it.

2. **No navigation unit.** Subjects were nominally the primary unit
   (`spec_first_navigation`), but the page was still an undifferentiated
   scroll; nothing communicated which subjects carried review weight.

Alternatives considered: keeping the single-scroll layout and only demoting
the triage hero (rejected — leaves the scope mixing intact); a file-first
layout with spec annotations (rejected — inverts the product's thesis);
separate HTML artifacts for change review vs. health (rejected — two links
per PR, and the health context belongs one click away, not one artifact
away).

## Decision

The artifact becomes a **master–detail review queue** with a **hard
change/repo-state split**:

- A left-rail queue lists every reviewable unit — Overview, Decisions
  changed, affected subjects grouped by change kind (spec edited / code
  only / impacted only, ordered by change size), the outside-the-spec-system
  panel, the all-files view, and Spec health. The detail pane renders one
  unit at a time; units are deep-linkable via URL fragment; the queue is
  filterable.
- **Overview is change-scoped only**: change verdict, diff-scoped counts,
  spec edits, the findings delta, file breakdown, changed decisions.
- **Spec health holds repo state**: the sync triangle, per-leg checks,
  strength inventories, and the full findings inventory, explicitly labeled
  as state at the head ref.
- **Findings are differential**: introduced / resolved / pre-existing,
  computed by diffing head findings against the base ref's committed
  `.spec/state.json` (`git show <base>:.spec/state.json`). The verdict chip
  reflects introduced findings only. Missing/unparseable base state degrades
  to an explicitly-labeled non-differential presentation.
- **Findings dedup by (code, reason)** into digest rows with counts and
  per-subject links.
- The four per-subject pivots survive, with change-scoped labels, a
  smart default pivot, and touched-requirements-first ordering on Coverage.
- **Degraded ≠ warning**: `:degraded` renders in a neutral (non-green,
  non-warning) tone with the `?` glyph; the v1 amber banner treatment made
  "couldn't check" read as "something is wrong". Partial verification is
  advertised on the Spec health pane and its queue badge, not by flipping
  the change verdict.
- **Theme-aware**: all styling flows through CSS custom-property tokens
  with light and dark value sets; default follows `prefers-color-scheme`;
  a system/light/dark toggle persists to localStorage.

The artifact remains self-contained, read-only, and identical local/CI —
`specled.decision.spec_review_html_viewer` is unchanged by this decision.

## Consequences

`SpecLedEx.Review.Html` is rewritten around the queue/detail structure; the
view-model in `SpecLedEx.Review` gains base-side finding extraction and
queue-grouping data but is otherwise already sufficient. Existing rendering
tests that assert v1 DOM structure must be rewritten alongside.

`mix spec.review` acquires a soft read-dependency on the base ref's
committed `.spec/state.json` for finding attribution. Repos that don't
commit state (or whose base predates it) lose the differential view but get
an honest label instead of misattribution — the fallback is mandatory, not
best-effort.

The change verdict reading "clean" while pre-existing findings exist at head
is deliberate: it scopes reviewer attention to the delta. The standing debt
remains one click away on Spec health and continues to gate `mix spec.check`
as before — nothing about verification semantics changes, only where each
fact renders.

Requirement statements for `triage_panel`, `degraded_leg_state`, and
`per_subject_tabs` are refined in place (same ids, same normative force,
relocated surfaces), and several v1 scenarios are rewritten to name the new
surfaces. This decision authorizes those wording changes.
