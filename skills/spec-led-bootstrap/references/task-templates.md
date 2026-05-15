# Beadwork task templates per phase

These are the verbatim bodies the bootstrap skill writes to each stage
ticket. They follow the same shape as `/distill`'s Phase 4 templates so
that `/implement` workers and `/orchestrate-epic`'s verifier/auditor can
read them without special-casing.

Substitution tokens:

- `<repo_root>` — absolute path to the worktree
- `<bootstrap_branch>` — branch the bootstrap is landing on
- `<subject.id>` — a specific subject id (phase1+ uses real ids)
- `<verify_cmd>` — the project verification command (default `mix spec.check`)

## phase0 — Install dep and scaffold .spec/

```
Advances: <none — meta phase>

Deliverable:
Install `spec_led_ex` as a dev/test dep and scaffold `.spec/` via
`mix spec.init`. Replace the `<PROJECT_VERIFICATION_COMMAND>` placeholder
in `.spec/AGENTS.md` with the project's actual verification command.

Verification:
- Tests to pass: `mix compile --warnings-as-errors && mix spec.check`
- Behaviors to demonstrate: `mix spec.check` exits 0 with at most
  `detector_unavailable` findings.

Out of Scope (files):
- lib/**/*
- test/**/*
- config/**/*
Allowed touches (this stage may modify):
- mix.exs
- mix.lock
- .spec/**/*
- .agents/skills/spec-led-development/**/*

Out of Scope (intent):
- Do not author subjects yet — phase1 owns that.
- Do not enable test_tags or coverage — phase3/4 own those.
- Do not raise severities — phase6 owns that.

Merge gate:
- [ ] `mix compile --warnings-as-errors` clean
- [ ] `mix spec.check` exits 0
- [ ] `.spec/AGENTS.md` has no `<PROJECT_VERIFICATION_COMMAND>` placeholder remaining
- [ ] Auditor APPROVE comment on the ticket
```

## phase1 — Carve subjects (parent ticket, fan-out optional)

```
Advances: <subject.id>[, <subject.id>...]

Deliverable:
Land .spec/specs/<id>.spec.md for the subjects accepted in extraction:
- <subject.id> — <one-line rationale from extraction>
- <subject.id> — <one-line rationale from extraction>
- ...

Each subject must have a populated spec-meta block (id, kind, status: draft,
summary, surface) and at least one placeholder spec-requirements entry.
Verifications are NOT wired in this phase.

Verification:
- Tests to pass: `mix spec.validate` (parser-clean) and `mix spec.check` (no new errors)
- Behaviors to demonstrate: `branch_guard_unmapped_change` now routes file
  edits inside the subjects' surface to the matching subject.

Out of Scope (files):
- lib/**/*
- test/**/*
Allowed touches:
- .spec/specs/**/*.spec.md
- .spec/decisions/**/*.md (only if a cross-cutting policy was discovered during extraction)

Out of Scope (intent):
- No code changes — this phase is spec authoring only.
- No `realized_by:` bindings — phase2 owns those.
- No status: active — drafts only.
- Do not invent requirements; placeholder text is fine.

Merge gate:
- [ ] Every accepted subject has a parsing `.spec.md` file
- [ ] `mix spec.validate` clean
- [ ] `mix spec.check` clean (no NEW errors vs base)
- [ ] Auditor APPROVE comment on the ticket
```

### phase1 fan-out child ticket (per subject)

When subject count > 3, use this template per child:

```
Advances: <subject.id>

Deliverable:
Author .spec/specs/<subject.id>.spec.md from the extraction draft. Surface
files (from extraction): <list>. Refine the placeholder requirements by
reading the modules' moduledocs and function @doc strings; promote any
behavior the docs assert to a concrete `must` requirement, keep speculative
behaviors as `should`.

Verification:
- Tests to pass: `mix spec.validate` parses the new file with no errors.
- Behaviors to demonstrate: `bw show <ticket-id>` description still names
  the subject; the spec file's `id` matches.

Out of Scope (files):
- lib/**/*
- test/**/*
- .spec/specs/*.spec.md (except <subject.id>.spec.md)
Allowed touches:
- .spec/specs/<subject.id>.spec.md

Out of Scope (intent):
- Authoring other subjects' specs — they have their own tickets.
- Adding `realized_by:` — phase2.
- Promoting to `status: active` — phase2.

Merge gate:
- [ ] `.spec/specs/<subject.id>.spec.md` exists and parses
- [ ] At least 1 must-priority requirement OR explicit note that all
      requirements are placeholders for phase2 review
- [ ] Auditor APPROVE comment on the ticket
```

## phase2 — api_boundary bindings

```
Advances: <every subject from phase1>

Deliverable:
For every subject from phase1, add a `realized_by.api_boundary:` block in
its spec-meta and promote `status: draft` → `status: active`. Use
`mix spec.suggest_binding` to generate proposals; review each one (it
proposes from `surface: lib/*.ex` only, so non-lib paths and internal
modules need human judgment).

Verification:
- Tests to pass: `mix spec.validate && mix spec.check --base origin/main`
- Behaviors to demonstrate: artificially renaming a bound MFA in lib/ now
  produces `branch_guard_realization_drift`. Removing one produces
  `branch_guard_dangling_binding`. (Demonstrate locally; do not commit
  the demonstration.)

Out of Scope (files):
- lib/**/*
- test/**/*
Allowed touches:
- .spec/specs/**/*.spec.md
- .spec/state.json   # regenerated by spec.check; commit the baseline

Out of Scope (intent):
- No code refactors to make bindings cleaner. The bindings adapt to the
  code, not the other way around.
- No `implementation:` tier — phase5.
- No `expanded_behavior:` / `use:` / `typespecs:` tiers — out of scope for
  bootstrap unless the user explicitly opted into them.

Merge gate:
- [ ] Every phase1 subject has `realized_by.api_boundary` with ≥1 MFA
- [ ] Every phase1 subject is `status: active`
- [ ] `mix spec.check --base origin/main` clean
- [ ] `.spec/state.json` committed with the new baseline
- [ ] Auditor APPROVE comment on the ticket
```

## phase3 — Test tags

```
Advances: <every subject with tagged tests>

Deliverable:
1. Set `test_tags.enabled: true, enforcement: warning` in .spec/config.yml.
2. For each subject with at least one existing test, add `@tag spec:
   "<requirement.id>"` to one test as a starter — this proves the wiring works.
3. For each subject the team wants to drive tagged tests on, add a
   `spec-verification` block with `kind: tagged_tests` covering the
   tagged requirements.

Verification:
- Tests to pass: `mix test` still green; `mix spec.check` still clean.
- Behaviors to demonstrate: `mix spec.check` now emits no findings for
  tagged requirements; deleting a tag re-fires
  `branch_guard_requirement_without_test_tag` as a warning.

Out of Scope (files):
- lib/**/*
- .spec/specs/**/*.spec.md  # except adding spec-verification blocks
Allowed touches:
- .spec/config.yml
- test/**/*_test.exs   # only adding @tag lines, no behavioral changes
- .spec/specs/**/*.spec.md   # only adding `kind: tagged_tests` verifications

Out of Scope (intent):
- Do not refactor tests while tagging. One commit per concern.
- Do not raise enforcement to error in this phase. phase6 owns lockdown.
- Do not delete or rewrite tests that lack tags — they are not a backlog;
  they tag opportunistically.

Merge gate:
- [ ] `test_tags.enabled: true, enforcement: warning` in config
- [ ] ≥1 `@tag spec:` per active subject
- [ ] ≥1 `kind: tagged_tests` verification across the corpus
- [ ] `mix test` and `mix spec.check` both clean
- [ ] Auditor APPROVE comment on the ticket
```

## phase4 — Coverage triangulation

```
Advances: <every subject opting into triangulation>

Deliverable:
1. Add SpecLedEx.Coverage.Formatter to test/test_helper.exs.
2. Run `mix spec.cover.test` locally to produce
   .spec/_coverage/per_test.coverdata; verify with `mix spec.triangle --all`.
3. Update CI workflow(s) to run `mix spec.cover.test` before `mix spec.check`.

Verification:
- Tests to pass: `mix spec.cover.test && mix spec.check`
- Behaviors to demonstrate: `mix spec.triangle <subject.id>` for any
  active subject reports coverage status for every requirement.

Out of Scope (files):
- lib/**/*
- .spec/specs/**/*.spec.md
Allowed touches:
- test/test_helper.exs
- .github/workflows/**/*.yml (or the equivalent CI files)
- .gitignore   # likely add .spec/_coverage/

Out of Scope (intent):
- No spec authoring — triangulation reads existing specs.
- Do not add `@tag spec_triangulation: :indirect` blindly — only on tests
  that legitimately exercise more subjects than they tag.

Merge gate:
- [ ] Coverage formatter wired in test_helper
- [ ] CI runs cover.test before spec.check
- [ ] `mix spec.triangle --all` exits 0
- [ ] Auditor APPROVE comment on the ticket
```

## phase5 — implementation tier (optional)

```
Advances: <subjects the user nominated for implementation-tier guarding>

Deliverable:
Add `realized_by.implementation:` blocks to the nominated subjects. The
compile tracer will hash the call closure; spec.check will fire
`branch_guard_realization_drift` on implementation-tier hashes after the
baseline is captured.

Verification:
- Tests to pass: `mix compile && mix spec.check --base origin/main`
- Behaviors to demonstrate: a no-op refactor of an implementation-tier
  function body does NOT produce drift (canonicalization handles it).
  An actual call-edge change DOES produce drift.

Out of Scope (files):
- lib/**/*
- test/**/*
Allowed touches:
- .spec/specs/**/*.spec.md
- .spec/state.json   # baseline regen

Out of Scope (intent):
- Do not add this tier to every subject — only the ones whose refactor
  pain motivated phase5.
- Do not author `expanded_behavior:` or `use:` or `typespecs:` — separate
  follow-ons if needed.

Merge gate:
- [ ] Nominated subjects have `realized_by.implementation:` with ≥1 MFA
- [ ] `mix spec.check` clean with new baseline committed
- [ ] Auditor APPROVE comment on the ticket
```

## phase6 — Lockdown

```
Advances: <none — meta phase>

Deliverable:
Graduate severities in .spec/config.yml:
- test_tags.enforcement: error
- guardrails.severities for the append_only/* and overlap/* codes the
  team trusts
- branch_guard.severities for branch_guard_dangling_binding and
  branch_guard_realization_drift

Verification:
- Tests to pass: `mix spec.check` clean on the bootstrap branch AND on
  HEAD~1 (proof the gates are passable today).
- Behaviors to demonstrate: a synthetic violation of each newly-error
  code produces a failing exit status locally (do not commit the
  violation).

Out of Scope (files):
- lib/**/*
- test/**/*
- .spec/specs/**/*.spec.md
Allowed touches:
- .spec/config.yml

Out of Scope (intent):
- Do not raise severities on detector_unavailable codes — they should
  stay warning so legitimate gaps surface visibly.
- Do not raise branch_guard_untested_realization to error in this PR;
  keep it at warning a while longer (per docs/adoption.md).

Merge gate:
- [ ] Severities raised in config
- [ ] `mix spec.check` clean
- [ ] Synthetic-violation rehearsal documented in the ticket comments
- [ ] Auditor APPROVE comment on the ticket
```

## Dependency wiring

After creating tickets, wire them in the linear order
phase0 → phase1 → phase2 → … → target_phase. For phase1 fan-out:

```bash
# parent → children
for CHILD in $PHASE1_CHILDREN; do
  bw dep add $PHASE1_PARENT blocks $CHILD
done
# children → next phase
for CHILD in $PHASE1_CHILDREN; do
  bw dep add $CHILD blocks $PHASE2_PARENT
done
```

This shape gives `/orchestrate-epic` a clean DAG: it parallelizes the phase1
children, then serially advances through phase2..6.

## Skipped phases

When the user opts out of a tier:

- `implementation` skipped → omit phase5 ticket; wire phase4 → phase6 directly.
- coverage triangulation skipped → omit phase4 ticket. In phase3, add the
  following config to phase3's Deliverable:
  ```yaml
  branch_guard:
    severities:
      branch_guard_untested_realization: :off
      branch_guard_underspecified_realization: :off
  ```
- Umbrella project → omit phase4 and phase5; cap target_phase at phase3 or
  phase6 (with reduced severities — only test_tags and append_only graduate).
