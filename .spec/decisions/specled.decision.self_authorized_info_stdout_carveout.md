---
id: specled.decision.self_authorized_info_stdout_carveout
status: accepted
date: 2026-08-12
affects:
  - specled.tasks.check_verbose_flag
change_type: adds-exception
reverses_what: >-
  Default mix spec.check output previously suppressed every info-severity
  finding detail unless --verbose or SPECLED_SHOW_INFO=1 was enabled.
---

# Self-Authorized Weakening Details Remain Visible by Default

## Context

`append_only/self_authorized_weakening` is an informational marker emitted when
a same-diff ADR authorizes a requirement weakening. Its info severity keeps the
authorized change non-blocking, while its requirement id, weakening class, and
ADR id give reviewers the detail needed to notice and evaluate the decision.

The default `mix spec.check` summary already counts info findings and discloses
that their details are hidden. That aggregate disclosure is insufficient for
this marker: without its detail line, a maintainer cannot tell which requirement
was weakened or which same-diff ADR authorized it. Raising the marker to warning
would change exit-status behavior under the strict gate, and showing every info
finding would discard the intentionally quiet default output policy.

## Decision

Default stdout filtering shall always retain findings whose code is exactly
`append_only/self_authorized_weakening`, even when their resolved severity is
info and neither `--verbose` nor `SPECLED_SHOW_INFO=1` is enabled. The carve-out
is code-based rather than message-based so wording changes cannot hide it.

All other info-severity findings remain suppressed by default. `--verbose` and
`SPECLED_SHOW_INFO=1` continue to show every finding, and the branch summary
format continues to describe the bulk info-detail mode as hidden or shown.
Because validation and branch findings share the same stdout filter, the code
carve-out applies consistently if this finding code ever reaches either path;
today it is emitted only by branch enforcement.

## Consequences

- **Positive:** A bare `mix spec.check` identifies the weakened requirement and
  its authorizing ADR without making an authorized change fail the gate.
- **Positive:** Bootstrap and diagnostic info findings retain the quiet default,
  including `append_only/no_baseline`.
- **Positive:** The existing summary grammar and verbose/environment flag
  semantics remain stable.
- **Negative:** Default suppression is no longer severity-absolute; callers
  that assumed no `[INFO]` detail lines without verbose output must account for
  this governance marker.

## Related

- `specled.decision.append_only_finding_budget_v2` — establishes the marker's
  info severity and per-requirement visibility purpose.
- `specled.decision.adr_append_only` — requires this explicit exception instead
  of silently weakening the stdout-filtering must.
- `specled.decision.change_type_enum_v1` — defines `adds-exception` for a
  requirement that remains in force with a specific carve-out.
