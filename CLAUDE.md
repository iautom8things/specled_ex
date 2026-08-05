# specled

specled is a Spec Led Development library for Elixir — repo-resident behavioral specs (`.spec/specs/*.spec.md`) with a verification loop (`mix spec.check`). Pure-Elixir Mix project: no Phoenix, no database, no Docker.

<!-- agentic.rules:start -->
## Rules

Detailed rules live in `.claude/rules/` (always loaded) and `.claude/dynamic-rules/` (loaded on demand: when a matching command runs, when a matching file is edited (write-only rules), or reference-only material you pull in by reading the file). Each file has frontmatter describing when it applies.

Run `.claude/scripts/rules-check --list` to see every rule (hook-gated, write-only, and always-on) at a glance.
<!-- agentic.rules:end -->

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

The verification gate before closing a task is `bash ./scripts/check_specs.sh`
(or `make check`). The wrapper arms `SPECLED_COMMAND_OUTPUT_DIR` at
`$ROOT/tmp/specled-command-output` so a failing or timed-out verification leaves
forensics; bare `mix spec.check` in a session whose project directory is a
checkout without `.claude/settings.json` leaves nothing. All targets for the
subjects you advanced must pass.

## Merge Gates

Before merging any new code, the following checks MUST pass:

- [ ] `mix compile --warnings-as-errors`
- [ ] `mix test`
- [ ] `mix format --check-formatted`
- [ ] `mix deps.unlock --check-unused`
- [ ] `mix xref graph --label compile-connected --fail-above 0`
- [ ] `bash ./scripts/check_specs.sh` (or `make check`)
