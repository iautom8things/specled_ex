---
id: specled.decision.tempfile_command_execution
status: accepted
date: 2026-04-07
affects:
  - specled.verification
change_type: clarifies
---

# Command Verification Shall Use Temp-File Output Capture

## Context

When `run_commands: true`, the verifier executes command verifications via
`System.cmd("sh", ["-lc", target])`. This creates a pipe for stdout that the
BEAM reads from. However, OTP's `erl_child_setup` — a long-lived helper process
that mediates all port spawning — retains a copy of the pipe's write-end file
descriptor. Even after the child shell exits, `erl_child_setup` keeps the fd
open (it lives for the BEAM's lifetime), so `System.cmd` never receives EOF and
blocks indefinitely.

This is a known OTP behavior: Erlang's own `os:cmd/1` avoids pipe EOF by using
a sentinel marker approach for the same reason. The issue is exacerbated when
the host project's supervision tree spawns long-lived port processes (file
watchers, tail processes, etc.) that inherit the fd through the same
`erl_child_setup` intermediary.

Projects that use spec-led with Phoenix, file system watchers, or any long-lived
Ports will hit this hang on `mix spec.check`.

## Decision

Replace `System.cmd` with a temp-file capture strategy:

1. Wrap the target command in `sh -c` with stdout/stderr redirected to a temp
   file and exit code written to a second temp file.
2. Spawn via `Port.open({:spawn, ...})` and wait for `:exit_status` (delivered
   via SIGCHLD/waitpid, not pipe EOF).
3. Read output and exit code from the temp files after the process exits.
4. Clean up temp files in an `after` block to handle crashes.

This decouples the data channel (files) from the signaling channel (exit
status), making the verifier immune to OTP fd inheritance behavior.

Additionally: drop `sh -lc` (login shell) in favor of `sh -c`. Login shells
source profile files that add non-determinism, startup cost, and potential side
effects. The parent BEAM's PATH is inherited by the child, which is sufficient
for `mix test` invocations. A configurable timeout (default 120 seconds)
prevents commands from blocking indefinitely.

## Consequences

- `mix spec.check` with `run_commands: true` completes reliably on all projects,
  including those with Phoenix, file watchers, or long-lived Ports.
- Command output is written to temp files in `System.tmp_dir!()`, adding minor
  disk I/O. Output size for test commands is small, so this is negligible.
- Temp files are cleaned up in an `after` block. On BEAM crash, orphaned files
  in `/tmp` are cleaned by the OS.
- Commands that depend on login shell profile setup (rare) must ensure PATH is
  set in the environment before invoking `mix spec.check`.
- A configurable timeout prevents indefinite hangs from stuck commands.
