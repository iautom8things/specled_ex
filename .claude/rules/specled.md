<!-- agent-rules: generated v0.14.0 -->
---
description: Specled — repo-resident behavioral specs and the verification loop. Specs are the source of truth for "what must be true."
# Deliberately NOT write_only: specs-as-source-of-truth must be in context when
# reading and planning, not only when editing.
paths:
  - ".spec/**"
  - "lib/**/*.ex"
  - "test/**/*.exs"
---

## Orientation

At session start, run the CI-equivalent structural gate to get a baseline
(cheap — no test execution):

```bash
mix spec.check --no-run-commands
```

## Cadence ladder — pick the right rung

Three rungs, lightest to heaviest. Do not overpay:

- `mix spec.validate` — lightest. Pure structural validation only.
- `mix spec.check --no-run-commands` — CI-equivalent: structural validate +
  branch guard + realization-drift + test-tag consistency, with **no**
  command/test execution. Cheap. Use this mid-iteration and whenever you want
  to "check like CI."
- `bash ./scripts/check_specs.sh` (or `make check`) — heaviest. All of the
  above **plus** executes every `execute: true` verification command (runs the
  tagged tests). Reserve for pre-PR preflight only. The wrapper arms
  `SPECLED_COMMAND_OUTPUT_DIR` at `$ROOT/tmp/specled-command-output` so a
  failing or timed-out verification leaves forensics; bare `mix spec.check` in
  a session whose project directory is a checkout without `.claude/settings.json`
  leaves nothing. The verdict is the last stdout line starting with
  `spec.check result=` — not `validate status=…`. A non-zero exit means failure
  even if no verdict line appears.

This repo's armed make target is `make check` (exports
`SPECLED_COMMAND_OUTPUT_DIR` to `$(CURDIR)/tmp/specled-command-output`).
Container-based repos may expose `make spec-check` / `make spec-check-full`
instead — same structural tiers, different arming.

## Files

- `.spec/specs/` — behavioral specs (one file per subject)
- `.spec/decisions/` — architectural decision records (the "why")
- `.spec/AGENTS.md` — agent operating guide for this project

Read `.spec/AGENTS.md` before implementing any feature.

Use `bw list --all --grep "Advances: <subject.id>"` to find tasks that advance a specific subject (`--grep` is literal, not regex). For planning-phase context, run `bw-plan prime` if that tooling is present in the repo.

## Implementing Against Specs

Beadwork tasks list the subjects they advance in an `Advances:` field (see `beadwork.md`). For each subject:

1. Read `.spec/specs/<subject>.spec.md`
2. Write code that satisfies the `spec-requirements` blocks
3. Write tests that cover the `spec-scenarios` blocks
4. Flip verification stubs from `execute: false` to `execute: true` as tests are added

## Verification Gate

Before closing a task, `bash ./scripts/check_specs.sh` (or `make check`) must
pass for every subject you advanced, the project must compile cleanly, and no
tests may regress. Prefer the wrapper over bare `mix spec.check` so
`SPECLED_COMMAND_OUTPUT_DIR` is armed.

## Spec Updates

If a requirement is wrong (impossible, contradictory, or misunderstood):

1. Update the requirement in the spec file
2. Update affected scenarios
3. Author a `.spec/decisions/` ADR if the change is architecturally significant
4. The PR must show: spec change + code change + verification passing

**Do NOT weaken specs to make failing code pass.**

## Generated vs committed state

- `.spec/state.json` is derived local state, written only on request
  (`mix spec.index --output .spec/state.json` or
  `mix spec.validate --output .spec/state.json`) — `mix spec.check` never
  writes it. It is never a source of truth, so never reason from it and never
  resolve a spec question by reading it.

  Whether it is *tracked* varies by repo — check before assuming
  (`git ls-files --error-unmatch .spec/state.json`):
  - **Untracked / gitignored** — it cannot conflict; leave it alone.
  - **Tracked** (the common case in the larger adopters) — it will conflict on
    rebase or merge whenever two branches touched specs. Treat the conflict as
    noise: take either side, finish the merge, then regenerate deliberately with
    `mix spec.index --output .spec/state.json` (not `mix spec.check`, which does
    not write it) and commit that. Do not hand-resolve the hunks.
- `.spec/realization_hashes.json` is the committed realization-hash baseline
  that drift detection compares against. Do NOT resolve conflicts in it by
  regenerating — that recomputes hashes from the merged tree and silently
  absorbs realization drift between branches. On conflict, prefer the side
  whose branch legitimately changed the named bindings, or keep both entries
  when different bindings moved on each branch.
- For diff and review purposes the source of truth is `.spec/specs/*.spec.md`,
  the code, and the tests.
