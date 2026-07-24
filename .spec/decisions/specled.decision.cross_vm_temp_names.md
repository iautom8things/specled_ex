---
id: specled.decision.cross_vm_temp_names
status: accepted
date: 2026-07-24
affects:
  - specled.verification
  - specled.tagged_tests
change_type: clarifies
---

# Shared-Tmp Temp Names Shall Be Cross-VM Unique via SpecLedEx.TempName

## Context

`System.unique_integer/1` is unique only within one BEAM VM. specled runs
nested (a `mix spec.check` merged run executes the host project's tests,
which may themselves exercise specled) and in parallel (concurrent CI jobs,
a human run racing an agent run), and all of those VMs share
`System.tmp_dir!()`. Two VMs can therefore generate the same
`specled_<kind>_<unique_integer>` name, and the loser's `File.rm`/`File.rm_rf!`
cleanup deletes the winner's in-flight file.

The observed failure modes escalate in subtlety:

- Command temp scripts (specled_-vnw, 0.5.2): the innocent run's script
  disappears mid-flight and the subject fails with exit 127.
- Streaming attribution sidecar (specled_-hyt): the outer merged run's
  `specled_attr_*.jsonl` is deleted or truncated by an inner test's cleanup,
  so a *completed* run silently degrades to shared fate and mass-reports
  `tagged_tests_cover_not_executed` (observed 2026-07-24: a 266-finding
  anomaly on a full `spec.check` that was clean on serial re-run).
- Review/base-view/diff parse temp files: a collision swaps or deletes
  another run's parse input, producing misparsed ADRs or spec diffs.

## Decision

Every temp file or directory name specled creates in shared locations
(`System.tmp_dir!()`, `SPECLED_COMMAND_OUTPUT_DIR`, write-rename siblings)
shall derive its uniqueness from `SpecLedEx.TempName.cross_vm_suffix/0`:
the OS pid (separates concurrently live VMs) plus 6 bytes of
`:crypto.strong_rand_bytes` hex (covers pid reuse against stale same-name
leftovers). `System.unique_integer/1` alone is not an acceptable uniqueness
source for any cross-VM-visible path in `lib/`; test-only usages remain
fine.

Exception: `SpecLedEx.Compiler.Tracer` executes inside a *host project's*
compile, where sibling specled modules may not be loadable (Mix prunes
undeclared deps from the code path), so it inlines the scheme as OS pid
plus `System.unique_integer/1`. That site is a write-rename sibling with no
cross-run cleanup, so pid separation alone already removes the deletion
hazard.

## Consequences

- One helper is the single audit point; new temp-file call sites reach for
  it instead of re-deriving the scheme, and drift between sites is
  impossible.
- Temp names grow by the pid and 12 hex chars; globs like `specled_attr_*`
  and `specled_cmd_*` are unaffected.
- The scheme is not crash-cleanup-aware: files orphaned by a killed VM are
  left for the OS tmp reaper, same as before.
