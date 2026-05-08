---
description: Worktree-first workflow. All implementation happens in a git worktree — never in the main checkout. Bootstrap via single atomic target; verify via smoke before work begins.
---

## Mandate

All development MUST happen in a worktree. The main checkout — the directory whose basename is `specled_ex` — tracks `main` and is reference only. Never commit from it or run tests in it. Run `make worktree-info` if you are unsure which mode you are in.

## The One Command

From the checkout that should act as the base:

    make worktree-new BRANCH=feature/my-feature

Use the main checkout when the new worktree should start from `main`. Use a long-lived
feature worktree when the new worktree should branch from that feature branch.

This is atomic. It runs all of: `git worktree add`, `mix deps.get`, `mix compile
--warnings-as-errors`, and `make smoke`. It exits non-zero on any failure. On success
it prints:

    ✓ READY at ../specled_ex-<slug>

## The Contract: `make smoke`

Before any implementation work in a worktree, `make smoke` MUST pass. It verifies:

- `mix.exs` exists at the worktree root
- `deps/` is populated
- `_build/` exists (project has been compiled at least once)
- `mix compile --warnings-as-errors` succeeds without recompiling everything

If smoke fails: run `make worktree-bootstrap` (idempotent) to repair, then re-run
`make smoke`. Do not proceed with work until smoke is green.

## Repair / Partial Bootstrap

If a worktree already exists but is broken or stale:

    cd ../specled_ex-my-feature
    make worktree-bootstrap   # idempotent — safe to re-run

This skips the `git worktree add` step and runs everything else.

## Worktree Admin

- `make worktree-info` — show current worktree config
- `make worktree-status` / `make wts` — all worktrees with git status
- `make worktree-cleanup NAME=<name>` / `make wtc NAME=<name>` — remove a single
  worktree by basename. Refuses if its branch is unmerged or its tree is dirty.
  Use this by default after landing a ticket.
- `make worktree-cleanup-all` / `make wtca` — sweep every worktree whose branch is
  fully merged into main. Use only when intentionally batching cleanup; it does not
  skip unrelated in-flight worktrees once they are merged.

## SpecLed Commands

specled commands run on the host worktree directly — there is no container layer.
They shell out to `git -C <root>` and need the worktree's Git metadata.

    mix spec.prime --base HEAD
    mix spec.next
    mix spec.next --bugfix
    mix spec.check
    mix spec.status

If host dependencies are missing, run `mix deps.get` (or `make worktree-bootstrap`)
in the worktree first.

## Checklist Before Implementing

1. `make worktree-info` — confirm you are in a worktree, not `specled_ex/` main
2. `make smoke` — confirm deps + build are healthy
3. If either fails, run `make worktree-bootstrap` and re-verify
