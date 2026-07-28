# `.spec` Agent Guide

Use this folder to maintain authored Spec Led Development subjects and generated state.

<!-- covers: spec.workspace.agents_present spec.workspace.agent_prime_context spec.workspace.reconcile_loop -->

## First Read

1. Read `.spec/README.md`.
2. Read `.spec/decisions/README.md` and any ADRs that affect the subject you are changing.
3. Read the current `.spec/specs/*.spec.md` files before editing.

## Working Rules

- Keep one subject per file.
- Put normative statements in `spec-requirements`.
- Add `spec-scenarios` only when `given` / `when` / `then` improves clarity.
- Add `spec-meta.decisions` only when a subject depends on a durable cross-cutting ADR.
- Keep ADRs in `.spec/decisions/*.md` for cross-cutting policy only. Do not use them for branch-local plans.
- Prefer targeted command verifications for behavioral proof.
- Use file-backed verifications only when the target can carry stable `covers:` markers for every covered id.
- Keep verification targets repository-root-relative.
- Use Git history and pull requests as the change log; keep `.spec` current-state only.
- At session start, run `mix spec.prime --base HEAD`.
- After code, docs, or tests change, run `mix spec.next`.
- For bug fixes, prefer `mix spec.next --bugfix`.
- If next says `needs subject updates`, update the named subject before you finish.
- If next says `ready for check`, move to `mix spec.check --base ...`. The verdict is the last stdout line starting with `spec.check result=` — not `validate status=…`. A non-zero exit means failure even if no verdict line appears.
- Use `mix spec.validate --debug` only when you need low-level verification output.
- Run `mix spec.status` when you need coverage or weak-spot summaries.

## Gate Forensics

`make check` and `scripts/check_specs.sh` arm `SPECLED_COMMAND_OUTPUT_DIR` at
`tmp/specled-command-output` (gitignored) whenever it is unset — note that
presetting it to the empty string defeats `make check`, whose `?=` treats empty
as set, after which the verifier's own `dir != ""` guard ignores it.
`scripts/check_specs.sh` is unaffected: POSIX `:-` substitutes on unset OR
empty, so it re-arms the default either way. CI points it at
the runner temp dir it uploads as an artifact.

`.claude/settings.json` also arms it for agent shells, but only for sessions
whose project directory is a checkout carrying that file — a session rooted at
an older checkout does not inherit it. Agent-shell coverage is therefore a
property of where the session was started, not a guarantee; run
`bash ./scripts/check_specs.sh` (or `make check`) when you need the capture
guaranteed, or check `echo $SPECLED_COMMAND_OUTPUT_DIR` first.

When a verification command fails or times out, that directory receives:

- `specled_cmd_<suffix>.log` — the command, exit code, timeout state, the tree
  provenance at run time (`git_head` and `git_dirty`), and the command's FULL
  output. Findings truncate that output and drop it entirely on timeout.
- `specled_cmd_<suffix>.attribution.jsonl` — for a merged `tagged_tests` run,
  the per-test evidence artifact the run streamed.

Read these before theorizing about a red gate leg you cannot reproduce. The
provenance lines are there because a finding's `file:line` is only valid
against the tree that ran: if the working tree changed between the gate run and
your inspection, the line has moved, and the test id in parentheses — not the
line — is authoritative.

## Generated vs Committed State

- `.spec/state.json` is fully derived local state. Generate it when you need
  low-level diagnostics (`mix spec.index --output .spec/state.json` or
  `mix spec.validate --output .spec/state.json`), but do not treat it as
  shared source-of-truth data.
- `.spec/realization_hashes.json` is the committed realization-hash
  baseline that drift detection compares against. Do NOT resolve conflicts
  in it by regenerating — that recomputes hashes from the merged tree and
  silently absorbs realization drift between branches. Its diffs read as
  subject-level realization changes; on conflict, prefer the side whose
  branch legitimately changed the named bindings, or keep both entries when
  different bindings moved on each branch.
