---
id: specled.decision.cross_vm_temp_names_reach
status: accepted
date: 2026-07-26
affects:
  - specled.binding
  - specled.branch_guard
  - specled.compiler_tracer
  - specled.index_state
  - specled.prose_guard
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

- The decision graph now names every subject whose surface creates or documents
  cross-VM-visible temp names.
- HashStore's atomic write path removes the last fixed-name write-rename
  sibling in `lib/`.
- The tracer exception is falsifiable: dropping the pid segment from the tmp
  sibling name breaks the compiler tracer proof.
- Site comments point at `SpecLedEx.TempName`; the helper moduledoc is the
  single narrative for the shared rationale.
