<!-- agent-rules: generated v0.13.1 -->
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
- `mix spec.check` (bare) — heaviest. All of the above **plus** executes every
  `execute: true` verification command (runs the tagged tests). Reserve for
  pre-PR preflight only.

Container-based repos may expose these as make targets (e.g. `make spec-check`
= `--no-run-commands`, `make spec-check-full` = bare) — the semantics are the
same.

## Files

- `.spec/specs/` — behavioral specs (one file per subject)
- `.spec/decisions/` — architectural decision records (the "why")
- `.spec/AGENTS.md` — agent operating guide for this project

Read `.spec/AGENTS.md` before implementing any feature.

Use `bw list --grep "Advances:.*<subject.id>"` to find tasks that advance a
specific subject. For planning-phase context, run `bw-plan prime` if that
tooling is present in the repo.

## Implementing Against Specs

Beadwork tasks list the subjects they advance in an `Advances:` field (see `beadwork.md`). For each subject:

1. Read `.spec/specs/<subject>.spec.md`
2. Write code that satisfies the `spec-requirements` blocks
3. Write tests that cover the `spec-scenarios` blocks
4. Flip verification stubs from `execute: false` to `execute: true` as tests are added

## Verification Gate

Before closing a task, `mix spec.check` must pass for every subject you advanced, the project must compile cleanly, and no tests may regress.

## Spec Updates

If a requirement is wrong (impossible, contradictory, or misunderstood):

1. Update the requirement in the spec file
2. Update affected scenarios
3. Author a `.spec/decisions/` ADR if the change is architecturally significant
4. The PR must show: spec change + code change + verification passing

**Do NOT weaken specs to make failing code pass.**

## `state.json` is generated — never hand-merge

`.spec/state.json` is produced by `mix spec.check` / `mix spec.validate` and will conflict on rebase or merge whenever two branches both touched specs.

- Treat conflicts in it as noise, not signal. Do not hand-resolve.
- During a rebase or merge, take either side (e.g. `git checkout --theirs .spec/state.json && git add .spec/state.json`), finish the merge, then regenerate with `mix spec.check` and commit the result.
- For diff and review purposes, ignore the file — the source of truth is `.spec/specs/*.spec.md`, the code, and the tests.
