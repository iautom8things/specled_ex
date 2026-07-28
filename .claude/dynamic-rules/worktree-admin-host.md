<!-- agent-rules: generated v0.14.0 -->
---
description: Worktree admin and cleanup make targets in host-run repos (host-shell / host-go / host-elixir).
# Structured gate (token membership), not a regex over the whole command string:
# a grep/rg that merely mentions one of these targets must not burn the
# once-per-session injection slot before the real admin command runs.
gate_command:
  - make
gate_args_any:
  - worktree-info
  - wti
  - worktree-status
  - wts
  - worktree-cleanup
  - wtc
  - worktree-cleanup-all
  - wtca
  - worktree-prune
should_match:
  - "make worktree-info"
  - "make wts"
  - "make worktree-cleanup NAME=my-wt WORKTREE_CLEANUP_BASE=main"
  - "make worktree-cleanup-all FORCE=1"
  - "make worktree-prune"
should_not_match:
  - "rg -n 'worktree-cleanup' docs/"
  - "grep -n 'make worktree-prune' CLAUDE.md"
  - "git commit -m 'document make worktree-cleanup-all'"
---

## Admin Commands

- `make worktree-info` / `make wti` - show current worktree configuration.
- `make worktree-status` / `make wts` - list worktrees with git status.
- `make worktree-cleanup NAME=<name>` / `make wtc NAME=<name>` - remove one
  clean worktree whose branch is merged into `WORKTREE_CLEANUP_BASE`. Pass
  `FORCE=1` to bypass the dirty + unmerged refusal gates.
- `make worktree-cleanup-all` / `make wtca` - remove all clean worktrees merged
  into `WORKTREE_CLEANUP_BASE`. With `FORCE=1`, also removes dirty/unmerged
  worktrees.
- `make worktree-prune` - prune stale git worktree metadata.

Set `WORKTREE_CLEANUP_BASE=main` when cleaning up after a PR lands. Leave the
default `HEAD` when cleaning a stage worktree after merging it into an epic
worktree.

Cleanup deletes the branch only after confirming it is merged into
`WORKTREE_CLEANUP_BASE`. If the worktree directory is already gone it finishes
the branch deletion instead of erroring, and it names any surviving remote
branch with the command to remove it.
