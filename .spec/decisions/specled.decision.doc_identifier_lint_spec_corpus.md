---
id: specled.decision.doc_identifier_lint_spec_corpus
status: accepted
date: 2026-07-23
affects:
  - specled.package
change_type: adds-exception
---

# The Doc-Identifier Lint Spans `.spec/**`; Unemitted Codes Need an Explicit Allow-Marker

## Context

The doc-identifier lint (`test/docs_identifier_lint_test.exs`) asserts that
every `append_only/*`, `overlap/*`, `evidence/*`, `cross_field/*`, or
`branch_guard_*` token in the corpus names a finding code the implementation
actually emits. Its corpus
was the user-facing guidance surface only — `skills/`, `docs/*.md`,
`README.md`.

Cold verification of specled_-ci0 found that fabricated codes survive in the
`.spec/**` workspace, which the lint never read: `branch_guard_test_only_change` <!-- spec-lint:allow-code=branch_guard_test_only_change fabricated code this decision names as the motivating example -->
(the same code specled_-ci0 removed from `concepts.md`) in a triangulation
scenario and in the finding-code budget, and `branch_guard_missing_subject_update_attested` <!-- spec-lint:allow-code=branch_guard_missing_subject_update_attested rejected-alternative code this decision names as the motivating example -->
in a rejected-alternative of an ADR. A fabricated code in a spec scenario or an
ADR misleads a reader exactly as much as one in a skill.

Two facts complicate a blanket extension:

- Decision records legitimately name codes that are **not** emitted — a code
  that was budgeted but never shipped, or one that was considered and rejected.
  A blanket `.spec/` exemption would restore the very blind spot this closes.
- Spec scenarios quote **atom-form** config (`x: :off`) as the *input under
  test*. That is not user guidance telling anyone to write the inert form, so
  the severity-form half of the lint must not reach into `.spec/**`.

## Decision

- The **finding-code integrity** half of the lint reads
  `skills/**/*.md`, `docs/**/*.md`, `README.md`, **and** `.spec/**/*.md`.
- The **atom-severity** half stays scoped to the user-facing guidance corpus
  (`skills/`, `docs/`, `README.md`); `.spec/**` scenarios quote atom-form config
  as fixtures by design.
- A finding-code token that no detector emits is exempt **only** when the same
  line carries an explicit, greppable marker naming that exact token:

      <!-- spec-lint:allow-code=<token> reason -->

  The marker exempts one token on one line. Typos and removed codes still trip
  the lint everywhere else, so the escape cannot become a silent blanket.
- The guarded set is every emitted family whose **token shape** identifies it
  as a finding code: the slash-namespaced `append_only/*`, `overlap/*`,
  `evidence/*`, and `cross_field/*`, plus the `branch_guard_*` prefix. Every
  other emitted code is a
  bare snake_case identifier — `detector_unavailable`,
  `spec_requirement_too_short`, and the several dozen validator and tag-scanner
  codes — and those are deliberately left unguarded rather than approximated by
  a stem pattern. Measured against the corpus, the candidate stems all collide
  with it: `detector_` matches the review-output field
  `detector_unavailable_by_leg` and a requirement id that embeds the same stem,
  and `decision_`, `verification_`, and `requirement_` match nine, four, and
  six non-code identifiers respectively — requirement ids, config keys, and
  field names. (The nine counts bare `decision_deleted`: the emitted code is
  the namespaced `append_only/decision_deleted`, which the lint already guards,
  so a `decision_` pattern would flag the bare spelling as fabricated.) Each
  would reject correct prose. The `must` names this boundary
  instead of claiming coverage the lint does not have.

  The must calls those four "heavily-referenced", on this basis: each occurs
  24-69 times in the scanned corpus (`detector_` 69, `requirement_` 45,
  `verification_` 39, `decision_` 24), against zero occurrences for every
  deferred stem. Corpus occurrences, not emitted-code counts — the two orders
  differ sharply, and conflating them is what produced an earlier draft calling
  these the "largest" stems when `detector_` matches exactly one emitted code.
  Occurrence count is the property the argument actually needs, since a stem
  that appears often in the corpus is the one likely to collide with it.

  That collision argument covers only the four stems named above. They match
  many of the unguarded codes but by no means all — many others are matched by
  none of the four — and at least five narrower stems (`surface_target_`,
  `scenario_cover_`, `meta_field_`, `spec_requirement_`, `invalid_id_`)
  collide with nothing in the corpus today.

  Deliberately no totals here. "How many codes does the implementation emit"
  has no answer until someone fixes whether `check/5` debug outputs count
  alongside `finding/5` findings, whether the three `Mix.raise` prefixes count,
  and whether a code reached only through a helper counts — choices that move
  the total by several either way, as two independent reviewers of this text
  found when they agreed on the comparison and disagreed on the denominator. A
  bare total invites that round trip every time the text is read. The
  comparative claim is the load-bearing one and is stable under every counting
  rule tried. Those clusters are guardable, at the cost of one more
  hand-maintained allowlist each — the reflection alternative stays rejected.
  That widening is deferred, not refused; it belongs with the rest of the lint
  hardening rather than in a spec-honesty fix.

  Keeping the two reasons apart is load-bearing, not pedantry. Collapsing them
  into "bare codes cannot be guarded" is what produced the overclaim this
  boundary text was written to replace, and the sentence refutes itself the
  moment anyone checks: `spec_requirement_too_short` is a bare code that none
  of the four large stems matches, and its own stem is collision-free.
- File-path segments that happen to match a token pattern (e.g. the trailing
  segment of `.../config/branch_guard_test.exs`) are not finding codes; the
  token patterns carry a `(?<![\w/])` lookbehind so a slash-prefixed path
  segment is never treated as a code and needs no marker.

Rejected: a blanket `.spec/` exemption (defeats the check); extending the
atom-severity check into `.spec/**` (false positives on fixture config);
reflection over `lib/` to derive the code set (the hand-maintained allowlist is
deliberately fail-loud — a new code must be added in the same change that starts
documenting it).

## Consequences

- Positive: a fabricated or removed code cannot hide in a subject spec or an ADR.
- Positive: decision records can still name budgeted/rejected codes, but only by
  making the "not emitted" status explicit and greppable at the reference.
- Negative: enforcement of the marker's *reason* text is social; the lint checks
  that the token is named, not that the justification is sound.
