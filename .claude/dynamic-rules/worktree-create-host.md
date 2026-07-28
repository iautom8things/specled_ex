<!-- agent-rules: generated v0.14.0 -->
---
description: Creating linked worktrees in host-run repos (host-shell / host-go / host-elixir) — branch source and the seed check.
# Structured gate (token membership), not a regex over the whole command string:
# a grep/rg that merely mentions the target name must not burn the once-per-session
# injection slot before the real `make worktree-new` runs.
gate_command:
  - make
gate_args_any:
  - worktree-new
  - wtn
should_match:
  - "make worktree-new BRANCH=feature/my-feature"
  - "make wtn BRANCH=feature/my-feature"
should_not_match:
  - "make -qp 2>/dev/null | grep -E '^worktree-new:'"
  - "rg -n 'worktree-new' docs/"
  - "git commit -m 'use make worktree-new for linked worktrees'"
---

## Create Worktrees

From the checkout that should act as the base:

```sh
make worktree-new BRANCH=feature/my-feature
```

The new branch is created from the current checkout's `HEAD`. This matters when
creating stage worktrees from a long-lived epic branch.

The worktree directory name is derived from the branch's last path segment, so
`feature/my-feature` becomes `<project>-my-feature`. That derived name is what
`make worktree-cleanup NAME=<name>` expects later.

Compose-based repos should adopt `worktree-create` instead of this rule; it
covers `COMPOSE_PROJECT_NAME` and the seed-source check.
