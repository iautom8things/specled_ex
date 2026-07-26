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
not an acceptable uniqueness source. Test-only usages remain fine.

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
