---
id: specled.decision.cross_vm_temp_names_reach
status: accepted
date: 2026-07-26
affects:
  - specled.binding
  - specled.branch_guard
  - specled.compiler_tracer
  - specled.index_state
  - specled.realized_by
  - specled.spec_review
  - specled.tagged_tests
  - specled.verification
change_type: supersedes
replaces:
  - specled.decision.cross_vm_temp_names
---

# Cross-VM Temp Name Reach Matches Shared Temp Surfaces

## Context

`specled.decision.cross_vm_temp_names` established the cross-VM temp-name
policy after collisions between nested or parallel BEAM VMs sharing tmp
locations made one run delete, truncate, overwrite, or misparse another run's
in-flight artifacts.

The original ADR under-claimed its graph reach: it affected verification and
tagged tests directly, but the same policy also governs review/spec-diff parse
inputs, base-view parse inputs, realization hash write-rename siblings, and the
compiler tracer's documented unloadable-module exception. That mismatch made
the durable decision less auditable than the code it was meant to constrain.

One concrete contradiction also remained: `SpecLedEx.Realization.HashStore`
wrote `.spec/realization_hashes.json` via the fixed sibling
`.spec/realization_hashes.json.tmp`. HashStore runs inside specled's own VM, so
the tracer's "sibling modules may not be loadable" exception does not apply.

## Decision

This ADR supersedes `specled.decision.cross_vm_temp_names` without changing its
core policy: every temp file or directory name specled creates in shared
locations (`System.tmp_dir!()`, `SPECLED_COMMAND_OUTPUT_DIR`, parse temp
directories, and write-rename siblings) shall derive its uniqueness from
`SpecLedEx.TempName.cross_vm_suffix/0`.

For any cross-VM-visible path in `lib/`, `System.unique_integer/1` alone is
not an acceptable uniqueness source.

`System.unique_integer/1`-named roots under `System.tmp_dir!()` in `test/` are
ACCEPTED RISK, not safe-by-construction. The nesting hazard is identical to
`lib/`'s: a `mix spec.check` merged run executes the host project's tests
inside a specled run, so two VMs can still mint the same root and one
`on_exit` `File.rm_rf!` can delete the other's scratch tree. The accepted
blast radius is a flaked test rather than a corrupted subject artifact, and
blanket conversion of every existing test root would drag their owning
subjects into branch-guard's impacted set for no semantic gain.

That permission does **not** extend to tests that assert on directory contents
(`File.ls!` over a shared or tmp root, or a cleanup sweep that deletes by glob
in a shared dir), because there a collision produces a false failure or raise
rather than a deleted scratch dir. The remedy depends on which half of the
class the test is in:

- A test that **allocates its own root** shall name that root with
  `SpecLedEx.TempName.cross_vm_suffix/0`, so the tree is cross-VM unique before
  any `File.ls!` or cleanup runs against it.
- A test that **reads or sweeps a genuinely shared directory it cannot
  uniquify** (e.g. `_build/<env>/.spec`) shall filter on the writer's
  `System.pid()` prefix instead. A freshly minted
  `SpecLedEx.TempName.cross_vm_suffix/0` embeds CSPRNG bytes present in no file
  on disk and therefore cannot match names another writer produced — using it
  as a filter would make a litter assert vacuous and a glob-delete sweep a
  no-op. Both the shared-root `File.ls!` assert and the after-sweep cleanup
  fall in this half.

New tests that allocate shared-tmp roots should reach for
`SpecLedEx.TempName.cross_vm_suffix/0` as well.

The HashStore write-rename sibling is not an exception. It shall use
`SpecLedEx.TempName.cross_vm_suffix/0` and therefore leave no fixed
`.spec/realization_hashes.json.tmp` collision point.

The sole exception remains `SpecLedEx.Compiler.Tracer`: it executes inside a
host project's compile, where sibling specled modules may not be loadable
because Mix prunes undeclared deps from the code path. The tracer may inline
the scheme, but the inlined suffix must include the OS pid. The remaining
VM-local counter is acceptable only after pid separation because that
write-rename sibling has no cross-run cleanup that could delete another VM's
in-flight file.

## Consequences

- The decision graph names the subjects that own the temp surfaces this ADR
  enumerates: `System.tmp_dir!()` command scripts and attribution artifacts,
  `SPECLED_COMMAND_OUTPUT_DIR` captures, review/base-view/spec-diff parse
  inputs, and write-rename siblings.
- `SpecLedEx.Evidence.Git.temp_path/2` is deliberately outside that set.
  It allocates under the repo-local `.git/specled-tmp`, which is none of the
  enumerated locations, and every name it returns already mixes 8 bytes of
  CSPRNG hex with the counter — so `System.unique_integer/1` is not acting
  alone there and no conversion is implied for `specled.evidence_store`.
- HashStore's atomic write path removes the last fixed-name write-rename
  sibling in `lib/`.
- The tracer exception is falsifiable: dropping the pid segment from the tmp
  sibling name breaks the compiler tracer proof.
- `SpecLedEx.TempName` moduledoc carries the shared rationale for the
  enumerated surfaces; each call site names the helper.
- `SpecLedEx.TempName.cross_vm_suffix/0` is public and available to tests
  (already used from `test/specled_ex/compiler/tracer_bootstrap_test.exs`).
  Existing test-only `System.unique_integer/1` roots that do not assert on
  directory contents are left alone under the accepted-risk carve-out above.
