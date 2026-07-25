<!-- agent-rules: generated v0.13.2 -->
---
description: Hard gate — raw `git worktree remove` / `git worktree prune` are blocked; use `make worktree-cleanup` / `make worktree-prune`.
# deny: always — the make targets are the only sanctioned teardown path; the
# hook only sees agent-issued commands, so make's internal git calls are unaffected.
# Structured gate (token membership) closes the `git -C <path> worktree remove`
# argument-variation bypass that the old adjacency regex missed.
deny_gate_command:
  - git
deny_gate_args_all:
  - worktree
deny_gate_args_any:
  - remove
  - prune
deny: always
should_deny:
  - "git worktree remove ../foo"
  - "git -C /repo worktree prune"
  - "cd /y && git worktree remove z"
  - "command git worktree remove x"
  - "ls; git status; git worktree remove ../wt; echo done"
  - "if [ -d ../wt ]; then git worktree remove ../wt; fi"
  - "timeout 30 git worktree remove ../wt"
  - "nohup git worktree remove ../wt"
should_not_match:
  - "git commit -m 'never run git worktree remove by hand'"
  - "rg -n 'git worktree remove|git worktree prune' docs/"
---

## Worktree teardown must go through `make`

You are about to run a raw `git worktree remove` or `git worktree prune`. In
this repo, both of those bypass `worktree-profile-before-cleanup` — the
per-profile teardown step that stops the worktree's Compose project, removes
its named volumes, and cleans up other per-worktree resources. Skipping it is
how worktrees that owned `<worktree>_*_build` / `<worktree>_*_deps` named
Docker volumes leave them behind forever.

Use the make targets instead:

```sh
# Single worktree, clean + merged
make worktree-cleanup NAME=<worktree-dir-name>

# Bypass dirty / unmerged refusal (still runs the cleanup hook)
make worktree-cleanup NAME=<worktree-dir-name> FORCE=1

# Batch-cleanup everything merged into WORKTREE_CLEANUP_BASE
make worktree-cleanup-all
make worktree-cleanup-all FORCE=1
```

`FORCE=1` exists so you can clean up a worktree whose branch never landed (was
abandoned, was experimental, or already-merged-elsewhere) without having to
commit garbage just to satisfy the refusal gates. The primary-checkout refusal
is never bypassable.

For orphaned **administrative metadata** (the linked worktree directory was
deleted out-of-band and `.git/worktrees/` needs cleaning), use
`make worktree-prune` — same effect as raw `git worktree prune`, but through
the sanctioned path. Raw `git worktree remove`/`prune` stay blocked every time.
