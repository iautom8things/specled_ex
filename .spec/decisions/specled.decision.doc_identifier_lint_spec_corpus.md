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
every `append_only/*`, `overlap/*`, or `branch_guard_*` token in the corpus
names a finding code the implementation actually emits. Its corpus was the
user-facing guidance surface only — `skills/`, `docs/*.md`, `README.md`.

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
