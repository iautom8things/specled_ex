<!-- agent-rules: generated v0.14.0 -->
---
description: Readiness gate before implementation work in host-run repos (host-shell / host-go / host-elixir).
# Structured gate (token membership), not a regex over the whole command string:
# a grep that merely mentions `make smoke` must not burn the once-per-session
# injection slot before the real readiness gate runs.
gate_command:
  - make
gate_args_any:
  - smoke
  - worktree-bootstrap
  - wtb
should_match:
  - "make smoke"
  - "make worktree-bootstrap"
  - "make wtb"
should_not_match:
  - "grep -n 'make smoke|verification' CLAUDE.md"
  - "rg -n 'make smoke' docs/"
  - "git commit -m 'run make smoke before implementation'"
---

## Readiness Gate

Before implementation, run:

```sh
make smoke
```

What smoke covers is profile-specific:

- host-shell: `git diff --check`, plus `bash -n` / `zsh -n` over every tracked
  script with a matching shebang.
- host-go: `go test ./...`.
- host-elixir: `mix compile --warnings-as-errors` and `mix test --max-failures 1`.

Repos add their own checks by giving `smoke` extra prerequisites; the generated
recipe still runs after them.

If smoke fails, run `make worktree-bootstrap`, repair the failure, and re-run
`make smoke` before changing product code. Do not start editing product code on
a red smoke — the gate exists so a pre-existing failure is never mistaken for
one your change introduced.

Compose-based repos should adopt `worktree-smoke` instead of this rule; it
covers Compose services, deps/migration drift and `WORKTREE_HEALTH_URL`.
