---
id: specled.decision.file_touch_yields_to_realization
status: accepted
date: 2026-05-12
affects:
  - specled.branch_guard
  - specled.realized_by
  - specled.binding
---

# File-touch guard yields to realization attestation

## Context

`mix spec.check`'s file-touch guard (`branch_guard_missing_subject_update` in
`SpecLedEx.BranchCheck.run/3`) is lexical: any change to a file in a subject's
covered set (built from `surface:` globs and `verification.target:` paths) that
is not co-changed with the corresponding `.spec/specs/<subject>.spec.md` fires
an `:error` finding and fails the run. The guard predates the realization tier
(`realized_by` + tagged-tests + coverage triangle, c.f.
[[specled.decision.realized_by_tier_implication]],
[[specled.decision.beam_first_binding_resolution]]).

When realization runs alongside the file-touch guard on a comment-only change
to a fully-bound file, the triangle correctly stays silent (the canonical AST
hash is unchanged, no drift finding fires) while the file-touch guard still
fails the run. The realization tier's evidence — stronger than spec.md
co-change because it inspects actual code state — is overruled by the older,
coarser check. This trains contributors to make ritual spec.md edits and
undermines the value of authoring `realized_by` bindings.

The desired behavior: when realization attests a `(file, subject)` pair as
clean for the current run, the file-touch finding for that pair downgrades from
`:error` to `:info` with a distinctive message naming the attesting bindings.
The `:info` finding remains visible so authors who genuinely want to update the
spec still see the prompt, but `mix spec.check` no longer fails on the case
where the triangle has already established that nothing semantically changed.

## Decision

`SpecLedEx.BranchCheck.run/3`'s `branch_guard_missing_subject_update` emit shall
yield to a per-(file, subject) attestation produced by the realization tier.

Attestation is **file-level**, not subject-level, and applies independently per
subject when a file impacts multiple subjects. The predicate for a `(file,
subject)` pair to be `:attested_clean` is the conjunction of:

1. At least one `realized_by` binding on `subject` resolves to a source file
   path (via the path-aware sibling of `SpecLedEx.Realization.Binding.resolve/2`)
   that equals the changed `file` after `Path.relative_to/2` normalization.
2. That binding does not appear in this run's
   `branch_guard_realization_drift` or `branch_guard_dangling_binding`
   findings.
3. The realization detector did not fail (no `detector_unavailable` for the
   tier providing the attestation).

All three conditions must hold. No partial credit. Tagged-tests targets covering
attested requirements expand to the corresponding test files (looked up via
`index["test_tags"][rid]`) and carry the same attestation reason.

When the predicate holds, the finding is emitted at `:info` (instead of `:error`)
with a distinctive message naming the attesting binding(s). The finding code
remains `branch_guard_missing_subject_update` — no new code is introduced. User
severity overrides via `SpecLedEx.BranchCheck.Severity.resolve/3` still win:
pinning the code to `:error` in `branch_guard.severities` re-asserts strict
mode regardless of attestation, and `:off` continues to absorb everything.

## Consequences

**Positive.** Authors making cosmetic edits to bound files no longer face a
red `spec.check` for a comment. The realization tier's evidence becomes
load-bearing — adopting `realized_by` is materially rewarded. Per-file grain
keeps the relaxation precise: a file that is in a subject's `surface:` glob
but not in any binding stays strict, preserving the "you need to acknowledge
this in the spec" prompt where it matters.

**Negative — falls back to strict on resolver failure.** When the path-aware
resolver returns `nil` (e.g., macro-generated functions where
`Module.module_info(:compile)` lacks `:source`, hot-reloaded modules, certain
protocol implementations), no attestation is produced and the strict
`:error` finding fires. This is a regression to today's behavior, not over-
relaxation. Acceptable failure mode; users mitigate by either updating the
spec.md or tightening the `realized_by` binding to a function that resolves
cleanly.

**Negative — depends on realization tier correctness.** A buggy detector
that silently produces false-clean attestations would silently relax the
guard. Mitigated by the three-condition conjunction (path returned + path
equals changed file + MFA not in drift/dangling set), by detector-unavailable
falling back to strict, and by test coverage on the resolver.

**Positive — non-breaking for projects without `realized_by`.** Subjects with
no `realized_by` produce no attestations; the file-touch guard fires exactly
as today. Adoption is the opt-in signal; no new feature flag is introduced.

## Alternatives considered

- **Subject-level deference** ("if a subject has any `realized_by` and
  realization said nothing about this subject, downgrade all its file-touch
  findings"). Rejected: too lenient. A subject with partial `realized_by`
  adoption would have its surface-glob-only files relaxed even when those
  files weren't examined by realization at all.
- **Project-wide flag to disable the file-touch guard.** Rejected: blunt;
  loses the strict-by-default for partially-adopted subjects.
- **New `cosmetic` / `comment_only` git trailer.** Rejected: bypasses
  realization entirely; the author asserts intent rather than the tooling
  earning the relaxation. Doesn't make `realized_by` adoption pay off.
- **New finding code (`branch_guard_missing_subject_update_attested`).**
  Rejected: bloats the finding-code budget (cf.
  [[specled.decision.append_only_finding_budget]]). Downgrading the existing
  code with a distinctive message conveys the same information without a new
  code to track in user severity configs.
- **Diff-aware analysis ("is the diff only comments / whitespace?").**
  Deferred. Useful as a future refinement orthogonal to this decision —
  doesn't replace realization attestation, but could catch the
  surface-glob-only cosmetic case after this decision lands.
