---
id: specled.decision.live_cross_field_gate
status: accepted
date: 2026-08-14
affects:
  - specled.decisions.cross_field_live_gate
  - specled.decisions.change_type_optional
change_type: refines
---

# CrossField Runs on the Live Index; Its Warnings Report at `info`

## Context

`SpecLedEx.DecisionParser.CrossField.validate/3` implements six `must`
requirements in `specled.decisions`, and until now nothing in production called
it. `SpecLedEx.Index.build/2` parsed ADRs through
`DecisionParser.parse_file/2`, which passes `current_index = nil`, and
`maybe_run_cross_field/3` returns the decision untouched on `nil`.
`validate_cross_fields/3` had no caller in `lib/`. Every cross-field rule was
enforced only by its own unit tests.

The cost was measured, not hypothetical: release 0.15.0 shipped three
`narrows-scope` ADRs with no `reverses_what:` — the combination
`specled.decisions.cross_field_reverses_what` says shall be an error — and
`mix spec.check` returned `result=pass`. They were corrected by hand in
`e71ac7bc`. The aggregate verifier duplicated part of the logic
(`valid_decision_affect?/4`) and let the rest through.

Two facts shape how the rules can be activated:

1. **The validator had never met a real index.** `resolvable_ids/1` read
   `subject["meta"]["id"]` with string keys, but `Index.build/2` produces
   schema structs with atom keys. Against the live corpus every subject id
   failed to resolve and R4 fired 55 `cross_field/affects_unresolved` errors on
   ADRs whose affects were correct. The fixtures that exercised R4 were all
   hand-built plain maps, so nothing caught it.
2. **`mix spec.check` validates with `strict: true`**, where one warning-severity
   finding fails the gate exactly like an error.

## Decision

`SpecLedEx.Index.build/2` runs the cross-field rules in a second pass, over the
index built from the same tree, after every ADR has been parsed. Ids resolve
through an accessor that reads both string-keyed maps and atom-keyed structs,
and the resolvable set is subject ids plus requirement and scenario ids — the
same claim set the live verifier accepts — plus decision ids for `replaces:`.

Severity is carried structurally rather than encoded in the message:
error-severity results land in a decision's `"parse_errors"`, warning-severity
results in a new `"parse_warnings"` list.

`SpecLedEx.Verifier` reports `"parse_warnings"` as
`decision_cross_field_warning` findings at **`info`** severity, not `warning`.
Under `strict: true` a warning is fatal, so reporting them at warning severity
would break every workspace holding a `change_type:`-less legacy ADR the moment
it upgrades — the outcome `specled.decisions.change_type_optional` exists to
prevent, since that requirement's whole purpose is that legacy ADRs and
bootstrap adoption paths keep working. The diagnostic remains warning-level
inside CrossField, which is what that requirement constrains. Adopters who want
the diagnostic to bite raise `decision_cross_field_warning` through
`verification.severities`.

Error-severity rules keep error severity. Those catch the 0.15.0 class of
defect, and unlike the missing-`change_type` warning they name a violation the
author can always fix.

## Consequences

- **Positive:** R1 through R6 now fail `mix spec.check` on the live path. The
  0.15.0 escape — a weakening ADR with no `reverses_what:` — is caught before
  merge.
- **Positive:** The two affect-resolution paths agree. CrossField's resolvable
  set matches what `Verifier.valid_decision_affect?/4` accepts, including the
  `repo.` prefix carve-out.
- **Negative:** Upgrading adopters whose ADRs violate an error-severity
  cross-field rule get a red gate on first run. That is the intended effect of
  activating an unenforced contract, and
  `specled.decision.adr_reverses_what_backfill` gives them a legal in-place
  repair for the one violation class their frozen ADRs cannot otherwise fix.
- **Negative:** Missing `change_type:` is reported below the fatal threshold by
  default, so a workspace that never raises the severity keeps accumulating
  unlabeled ADRs. The branch guard's `append_only/missing_change_type` still
  reports them on change.
- **Negative:** `Index.build/2` now parses decisions in two passes, so ADR
  parsing costs one extra traversal of the decision list.

## Related

- `specled.decision.repo_namespace_affect_carveout` — the `repo.` prefix
  exemption both paths must honor, added when this wiring was still pending.
- `specled.decision.deprecates_affect_reference_carveout` — the R6 carve-out
  that keeps deprecation targets exempt from resolution.
- `specled.decision.adr_reverses_what_backfill` — the in-place repair this
  activation makes necessary.
