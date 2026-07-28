<!-- agentic-worktree: module=host-elixir version=0.27.0 -->

---
description: Worktree-first workflow for host-run Elixir projects.
---

## Mandate

All implementation work happens in a linked git worktree. The primary checkout
tracks `main` and is reference-only for normal feature work.

The core loop:

- Create: `make worktree-new BRANCH=<name>` (branches from the current
  checkout's `HEAD`).
- Gate: run `make smoke` before changing product code; on failure run
  `make worktree-bootstrap`, repair, and re-run smoke. For this profile smoke
  verifies `mix compile --warnings-as-errors` and `mix test --max-failures 1`.
- Inspect: `make worktree-status` / `make worktree-info`.
- Clean up: `make worktree-cleanup NAME=<name>` — never raw
  `git worktree remove`/`prune`, which skip `worktree-profile-before-cleanup`
  and leak whatever that teardown owns.

The detail behind each of these — creation mechanics, what smoke actually runs,
the admin command table, `WORKTREE_CLEANUP_BASE` and the `FORCE=1` refusal
gates — auto-loads the moment a matching command runs, via the `.claude/rules/`
injection hook (`worktree-create-host`, `worktree-smoke-host`,
`worktree-admin-host`, `worktree-cleanup`; adopt with
`sync-agent-rules --repo <repo> --adopt <names>`). It is not reproduced here so
this file stays small in every session's context.
