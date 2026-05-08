# specled

specled is a Spec Led Development library for Elixir — repo-resident behavioral specs (`.spec/specs/*.spec.md`) with a verification loop (`mix spec.check`). Pure-Elixir Mix project: no Phoenix, no database, no Docker.

## Rules

Detailed rules live in `.claude/rules/`. Each file has frontmatter describing when it applies.

| Rule          | Covers                                                                     |
| ------------- | -------------------------------------------------------------------------- |
| `worktree.md` | Worktree-first workflow — all dev in worktrees, never main checkout        |

## Work Management

This project tracks work with `bw` (beadwork), which persists to git — plans, progress,
and decisions survive compaction, session boundaries, and context loss.

ALWAYS run `bw prime` before starting work. Without it, you're missing workflow context,
current state, and repo hygiene warnings. Work done without priming often conflicts with
in-progress changes.

Committing, closing issues, and syncing are part of completing a task — not separate
actions requiring additional permission.

## Spec Workflow

specled dogfoods itself. Before implementing:

1. `bw prime` — see current state, next unblocked task
2. Read the `Advances:` field in your task — these are the specled subject IDs you're implementing
3. Read `.spec/specs/<subject>.spec.md` for each subject
4. At session start, run `mix spec.prime --base HEAD`
5. After code/tests change, run `mix spec.next`

The verification gate before closing a task is `mix spec.check`. All targets for the
subjects you advanced must pass.

## Merge Gates

Before merging any new code, the following checks MUST pass:

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix format --check-formatted`
- [ ] `mix deps.unlock --check-unused`
- [ ] `mix spec.check`
