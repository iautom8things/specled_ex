---
id: specled.decision.gate_failure_forensics
status: accepted
date: 2026-07-26
affects:
  - specled.verification
  - specled.tagged_tests
change_type: extends
---

# A Failing Gate Run Shall Leave Enough Evidence To Diagnose Without Reproducing

## Context

Three flake classes have now been chased in this repo's own gate path, and each
investigation ran into the same wall: the run that failed was the only run that
failed, and nothing survived it.

The findings a red gate emits are deliberately lossy. Command output is
truncated on failure and dropped entirely on timeout, and a merged
`tagged_tests` run distils its attribution artifact down to a list of test
descriptors before deleting the artifact itself. That is right for a report
someone reads in a terminal, and useless as evidence. The forensic capture
gated on `SPECLED_COMMAND_OUTPUT_DIR` already existed for exactly this, but was
unset in every environment where the flakes were actually observed, so it never
fired once.

The 2026-07-26 investigation added a second failure mode that no amount of
output would have fixed. A gate report named a failing test at
`test/docs_identifier_lint_test.exs:255`; the line was blank when someone
looked. Git archaeology established that the session had been editing that file
between gate runs, so the report was generated against one tree and read
against another, six lines off. Nothing in the report could distinguish that
from a reporting bug, and the reporting path was suspected — wrongly — for most
of a session.

Both are the same problem: evidence that identifies itself only relative to the
run that produced it, on a run nobody can reproduce.

## Decision

A verification run that fails or times out shall leave behind evidence
sufficient to diagnose it without re-running it. Concretely, three rules apply
across `specled.verification` and `specled.tagged_tests`:

1. **Descriptors are self-identifying.** A test named in a finding carries both
   its `file:line` and the formatter's event id (`Module.test name`). The
   location is relative to the tree that ran; the id is not.

2. **The capture records its own provenance.** Each output capture records the
   verification root's git HEAD and dirty path list at run time, so
   report-versus-inspection tree skew is detectable rather than inferred from
   archaeology.

3. **Primary evidence outlives the run.** When a merged `tagged_tests` run's
   output is captured, its attribution artifact is preserved alongside it under
   the same basename, instead of being deleted with the rest of the run's temp
   files.

The capture stays opt-in via `SPECLED_COMMAND_OUTPUT_DIR` — a library must not
write to a consumer's filesystem uninvited — but the gate paths this repo owns
arm it by default. An instrument that is off in every environment where the
fault occurs is not an instrument.

Two of those paths are unconditional: CI, and the `make check` /
`scripts/check_specs.sh` wrappers. The third is not, and the difference is
worth stating rather than glossing. `.claude/settings.json` arms agent shells
only for sessions whose project directory is a checkout carrying this file, so
a session rooted at a checkout that predates this change is not covered —
measured, during this ticket's own verification. Coverage of the agent-shell
path is therefore a property of where the session was started, not a guarantee;
see specled_-4f7 for the residual.

The settings value is relative. That is harmless only because no gate path can
run with a working directory other than the repo root — `mix` refuses without a
`mix.exs`, `make` without a Makefile, and `scripts/check_specs.sh` cd's to the
git toplevel first. If a future gate path can be invoked from a subdirectory,
that relative value starts scattering captures and must become absolute.

## Alternatives Rejected

- **Rely on reproduction.** Every flake in this class has failed to reproduce:
  green on immediate re-run, green in isolation, green under synthetic load.
  A policy that assumes reproduction has no failure mode left to work with.
- **Widen the findings instead.** Findings are read in a terminal and appear
  once per participating subject; embedding full suite output and a per-test
  event stream in each of them trades a diagnosable failure for an unreadable
  report.
- **Capture unconditionally, no env var.** This writes to the consuming
  project's filesystem on every red verification, with no way to decline.
  Default-on belongs in the gate wrappers, which the consuming project owns,
  not in the library.

## Consequences

- Finding messages naming failing or hung tests are longer: each descriptor now
  carries a parenthesized test id. Existing consumers that matched the bare
  `file:line` prefix still match; anything anchoring the end of a descriptor
  does not.
- An armed capture directory accumulates one log per failing command, plus one
  JSONL artifact per failing merged run. Repo-local defaults point at
  gitignored `tmp/`; CI points at the runner temp dir it uploads.
- Each capture costs at most two `git` invocations at write time — one outside
  a work tree, where `rev-parse HEAD` fails and the dirty query is skipped.
  They run only on the failure path, and a root that is not a work tree records
  the provenance as unavailable rather than failing.
- The preserved artifact holds the same per-test data the run streamed —
  module, test name, file, line, spec ids, state. It is evidence about the test
  suite, not about the code under test, and carries nothing the repository does
  not already contain.
