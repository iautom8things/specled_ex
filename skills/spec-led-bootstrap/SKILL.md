---
name: spec-led-bootstrap
description: "Use when the user wants to adopt SpecLedEx in a repository — installing the dep, scaffolding `.spec/`, extracting initial subjects from existing code, and producing a phased beadwork epic the user (or /orchestrate-epic) can drive to completion. Trigger phrases: 'bootstrap spec-led', 'adopt specled', 'set up spec-led', 'install spec-led-development', 'extract specs for this repo', 'spec-led-bootstrap'. NOT for repos that already have a healthy `.spec/` — use /spec-led-development for ongoing maintenance."
argument-hint: "[--target greenfield|brownfield|infer] [--depth phase0|phase1|phase2|phase4|phase6]"
---

# /spec-led-bootstrap — Land SpecLedEx in a Repository

## What this skill does

Bootstraps SpecLedEx adoption in an Elixir repository from any starting state.
It is **state-detecting, target-driven, and beadwork-tracked**:

1. **Detect** — read what is already in place (dep, `.spec/`, specs, conformance,
   adoption-phase signals) and classify the repo's current state.
2. **Target** — choose how far down the adoption ladder this bootstrap should
   carry the repo. The brownfield ladder has six phases; bootstrap can stop at
   any of them.
3. **Extract** (when needed) — for repos with no specs, propose subject
   boundaries from existing module structure. This is the hard step and gets
   its own ceremony — see [references/subject-extraction.md](references/subject-extraction.md).
4. **Emit** — produce a beadwork epic whose stage tickets are shaped so that
   each phase ships as one PR. The tickets are compatible with `/implement`
   and the whole epic is drivable by `/orchestrate-epic`.

This skill is the **on-ramp**. Once the epic lands and the triangle is closed,
use `/spec-led-development` for ongoing spec maintenance and `/distill` for
new feature work.

## When to invoke vs related skills

| Situation                                          | Skill                      |
|----------------------------------------------------|----------------------------|
| Repo has no `.spec/` or no specled dep             | **`/spec-led-bootstrap`**  |
| Repo has `.spec/` + drafts but no bindings/tags    | **`/spec-led-bootstrap`**  |
| Repo already has triangle closed, maintaining it   | `/spec-led-development`    |
| Translating a `/mega-plan` output into specs       | `/distill`                 |
| Executing a single ticket against an authored spec | `/implement`               |
| Driving an epic of /implement tickets to done      | `/orchestrate-epic`        |

If the user invokes `/spec-led-bootstrap` on a healthy repo, the detection
phase will identify that and offer to hand off to `/spec-led-development`
rather than re-doing work.

---

## Phase 0: Preconditions and worktree gating

Before any writes:

1. **Confirm Elixir project.** `ls mix.exs` must succeed. If not, halt and
   tell the user — SpecLedEx is Elixir-only.
2. **Worktree-first check.** Use the same gate as `/distill` (Phase 0): if
   the project has `.claude/rules/worktree.md` (or equivalent) **and** the
   current cwd is the main checkout (`git rev-parse --git-dir` ==
   `git rev-parse --git-common-dir`), do NOT write to main. Prefer the
   auto-create path: `make worktree-new BRANCH=spec-led/bootstrap` (or the
   project's equivalent target), then continue against the new worktree
   using absolute paths.
3. **bw check.** Run `bw list 2>/dev/null` to confirm beadwork is initialized.
   If absent, fall back to writing a Markdown `.spec/_bootstrap_plan.md` plan
   instead of bw tickets, and tell the user once.

Record `repo_root` (absolute path to the worktree where writes will land) and
`bootstrap_branch` (the branch name) — these are used in every subsequent phase.

---

## Phase 1: Detect current state

Run the detection matrix. Each signal is cheap; collect them all before
deciding what to do. The full matrix with rationale is in
[references/detection-matrix.md](references/detection-matrix.md); the
summary checklist:

### 1.1 Dependency state

```bash
grep -E 'spec_led_ex|specled_ex' mix.exs
mix deps | grep -E 'spec_led_ex|specled_ex' 2>/dev/null
```

- **No mention in `mix.exs`** → dep needs to be added.
- **Mentioned but not in `mix.lock`** → run `mix deps.get`.
- **Locked and present** → installed.

### 1.2 Workspace state

```bash
ls .spec/                                 2>/dev/null
ls .spec/config.yml                       2>/dev/null
ls .spec/specs/*.spec.md                  2>/dev/null
ls .spec/decisions/                       2>/dev/null
ls .spec/state.json                       2>/dev/null
ls .spec/_coverage/per_test.coverdata     2>/dev/null
```

Classify into one of five **workspace tiers** (see detection matrix for the
exact decision rules):

| Tier             | Signal                                                    |
|------------------|-----------------------------------------------------------|
| **T0 absent**    | No `.spec/` directory.                                    |
| **T1 scaffold**  | `.spec/` exists; zero or only template subjects.          |
| **T2 drafts**    | Subjects exist but most are `status: draft`, no bindings. |
| **T3 partial**   | Some subjects bound (`realized_by:`), some tests tagged.  |
| **T4 closed**    | Triangle closed; CI runs `spec.check`.                    |

### 1.3 Conformance check

If any spec files exist, run:

```bash
mix spec.validate
mix spec.check --base HEAD~1
```

Classify findings into:

- **Schema-fatal** (`parser/*`, malformed YAML): the spec file does not parse;
  it must be repaired before any new authoring.
- **Validator findings** (`append_only/*`, `overlap/*`, `branch_guard_*`):
  spec corpus drifted from code; bootstrap should include cleanup tasks.
- **`detector_unavailable`**: a tier opted-in but its inputs are missing
  (e.g. no coverage artifact). This is normal during adoption — record it
  so we know which tiers are currently dark.

### 1.4 Adoption-level signals

```bash
# test-tags enabled?
grep -E 'enabled:\s*true' .spec/config.yml 2>/dev/null | head -1

# @tag spec: present in tests?
grep -rE '@(tag|moduletag)\s+spec:' test/ 2>/dev/null | head -5

# coverage formatter wired?
grep 'SpecLedEx.Coverage.Formatter' test/test_helper.exs 2>/dev/null

# CI integration?
grep -rE 'mix spec\.(check|cover\.test)' .github/ 2>/dev/null
```

Each line answered "yes" raises the inferred current phase by one. Compute
the **current_phase** as the highest phase whose preconditions all hold,
floor at 0:

- **phase0** — dep + `.spec/` scaffold only
- **phase1** — at least one non-draft subject with `surface:`
- **phase2** — at least one subject with `realized_by.api_boundary:`
- **phase3** — `test_tags.enabled: true` AND at least one `@tag spec:`
- **phase4** — coverage formatter wired AND `.spec/_coverage/per_test.coverdata` produced at least once
- **phase5** — at least one subject with `realized_by.implementation:`
- **phase6** — `test_tags.enforcement: error` AND `branch_guard.severities.*: error` raised on the high-trust codes

### 1.5 Codebase shape (for subject extraction)

If `current_phase < phase1`, also collect inputs for subject extraction:

```bash
# Count app modules
find lib -name '*.ex' | wc -l

# Top-level lib structure (subjects often cluster here)
find lib -maxdepth 2 -type d

# Test surface
find test -name '*_test.exs' | wc -l

# Phoenix / Ecto / behaviour hints
grep -rlE '^\s*(use Phoenix\.Controller|use Ecto\.Schema|@behaviour|defmacro)' lib/ | head -20
```

The output of 1.5 feeds Phase 3 (subject extraction).

### Detection summary

Print one short table to the user:

```
Repo: <repo-name> @ <bootstrap-branch>
Dep: <installed|missing|locked-only>
Workspace: <T0|T1|T2|T3|T4>
Conformance: <clean|N validator findings|schema-fatal>
Current phase: phase<N> (<one-line rationale>)
Modules / tests: <M> / <T>
```

---

## Phase 2: Choose adoption target

Ask the user exactly once how far down the ladder to drive this bootstrap.
Use the detected `current_phase` to pre-fill a recommendation; never force.

The full ladder description with cost/benefit is in
[references/adoption-phases.md](references/adoption-phases.md). The short
version:

| Target  | What it adds                                               | Typical cost   |
|---------|------------------------------------------------------------|----------------|
| phase0  | Install dep + scaffold `.spec/`. No subjects yet.          | <1 hour        |
| phase1  | Carve N subjects with `surface:`, `status: draft`.         | 1–2 PRs        |
| phase2  | `realized_by.api_boundary:` on every subject; status active. | 1 PR per subject cluster |
| phase3  | Test-tag scanner enabled (warning); start tagging tests.   | Ongoing        |
| phase4  | Coverage formatter wired; full triangle online.            | 1 PR + CI wire |
| phase5  | `realized_by.implementation:` for refactor-heavy subjects. | Optional       |
| phase6  | Severities graduated to error; lock down.                  | 1 PR after green |

**Defaults the skill recommends:**

- Greenfield (no existing code, `mix new` fresh) → recommend **phase4** (full
  triangle from day one is cheap when there is nothing to retrofit).
- Brownfield, T0–T2 → recommend **phase2** as the first bootstrap target.
  Phases 3+ ship as follow-on epics once the muscle memory is built.
- Brownfield, T3+ → recommend completing whichever phase is partially done,
  then stopping (let the team graduate independently).

Also surface the **configurable levers** so the user can opt out of tiers
they will never use (see [references/configurable-levers.md](references/configurable-levers.md)):

- Skip `implementation` tier indefinitely if churn is mostly new features.
- Skip coverage triangulation indefinitely if the test suite is already slow.
- Umbrella project? The `realized_by` tiers degrade to
  `detector_unavailable :umbrella_unsupported`; tagged-tests and ADR
  governance still work — bootstrap should target phase3, not phase4.

Record `target_phase` and any per-tier opt-outs.

---

## Phase 3: Subject extraction (only if `current_phase < phase1`)

This is the **worst-case** path: no specs exist and we must propose subjects
from the existing code. The procedure is in detail in
[references/subject-extraction.md](references/subject-extraction.md); the
high-level steps:

### 3.1 Cluster modules into subject candidates

Heuristics, applied in order:

1. **Phoenix contexts.** Each `lib/<app>/<context>/` directory under a
   Phoenix app maps to one candidate subject. The context module
   (`<App>.<Context>`) and its child modules form the cluster.
2. **Behaviour-defining modules.** Any module that declares `@callback` is a
   strong subject anchor — its callbacks define the surface.
3. **GenServer / supervisor trees.** Each top-level supervisor's children
   form a candidate cluster.
4. **Top-level lib directories.** For non-Phoenix apps, `lib/<app>/*` at
   depth 2 — each directory with ≥2 modules is a candidate.
5. **Public APIs.** A module with many exported functions and no calls from
   other lib modules is often a public API — candidate for its own subject.

For each candidate produce a record: `{ proposed_id, surface: [...],
rationale: <one line> }`.

### 3.2 Filter and present

- Merge candidates that overlap on >50% of their surface.
- Drop candidates with <2 source files (probably not worth a subject).
- Sort by file count desc.

Present the list to the user (max 20 at once) and ask which to accept,
which to defer, which to merge or split. Show the rationale per candidate so
the user can override quickly. **Defer is the safe default for anything the
user is unsure about** — uncovered files surface later as
`branch_guard_unmapped_change` warnings, which is the natural prompt to
carve another subject.

### 3.3 Produce subject drafts

For each accepted candidate, write `.spec/specs/<id>.spec.md` with:

- `spec-meta` block:
  - `id: <namespace>.<subject_slug>`
  - `kind: module` (default) — adjust to `workflow`/`policy`/`integration` per the candidate's nature
  - `status: draft` — explicit; do not promote until phase2 wires bindings
  - `summary:` one-liner
  - `surface:` paths from the cluster
- A `spec-requirements` block with **one starter requirement per public
  function the candidate exports**, marked `priority: should` and
  `stability: evolving`. These are placeholders the user (or `/implement`
  worker) will refine. The draft status keeps them from gating CI.
- No `spec-verification` block yet — added in Phase 4/5 of the emitted epic
  (phase2 work in the adoption ladder).

This step is intentionally proposal-only. Never overwrite an existing spec
file; if `<id>.spec.md` exists, skip and record a conflict.

---

## Phase 4: Emit beadwork epic

Now translate the (target_phase, subjects, opt-outs) tuple into a beadwork
epic. The epic is shaped so that `/orchestrate-epic` can drive it.

The full templates per phase are in
[references/task-templates.md](references/task-templates.md). The shape:

### 4.1 Create the epic

```bash
bw create "Adopt SpecLedEx to <target_phase>" -t epic --description "$(cat <<'EOF'
Bootstrap epic produced by /spec-led-bootstrap.

Target phase: <target_phase>
Subjects in scope: <N>
Worktree: <repo_root>
Branch: <bootstrap_branch>

Per-tier opt-outs:
- implementation tier: <on|skipped>
- coverage triangulation: <on|skipped>

Reference: docs/adoption.md in the specled_ex repo for the full ladder.
EOF
)"
```

Capture the epic id as `$EPIC`.

### 4.2 Stage tickets — one per adoption phase up to `target_phase`

Each phase becomes one ticket, **created as a child of `$EPIC`**, with
dependencies wired so `orchestrate-epic`'s DAG drives them in order:

```
phase0  →  phase1  →  phase2  →  phase3  →  phase4  →  phase5  →  phase6
```

Stop at `target_phase` — do not create tickets past it.

Each ticket follows the `/distill` Phase 4 template (Advances:, Deliverable:,
Verification:, Out of Scope (files), Allowed touches, Out of Scope (intent),
Merge gate). The specifics per phase are templated in
[references/task-templates.md](references/task-templates.md).

**phase1 fan-out (special case).** When subject count > 3, phase1 is split
into N sub-tickets — one per subject cluster — under a phase1-parent ticket.
Each carries `Advances: <subject.id>` for its cluster only. This lets
`/orchestrate-epic` parallelize across subjects while the phase1 parent
gates phase2.

### 4.3 Dependency wiring

```bash
bw dep add <phase0-id> blocks <phase1-id>
bw dep add <phase1-id> blocks <phase2-id>
# ... up to target
```

Within phase1's fan-out, all sub-tickets block the phase1 parent's close
(or use `bw dep add <subticket> blocks <phase2-id>` directly if you skip the
parent and depend phase2 on the fan-out).

### 4.4 Per-tier opt-out handling

- `implementation` skipped → omit the phase5 ticket entirely.
- `coverage triangulation` skipped → omit phase4 ticket; collapse phase3's
  ticket to also write a permanent `:off` for `branch_guard_untested_realization`
  and `branch_guard_underspecified_realization` in `.spec/config.yml`.
- Umbrella → phase2 ticket includes the note that `realized_by` tiers will
  emit `detector_unavailable :umbrella_unsupported`; phase4/5 tickets are
  omitted unless v1.1 of SpecLedEx is in the dep.

---

## Phase 5: Hand off

Print to the user:

```
Bootstrap epic ready: <epic-id> ("<title>")
Stage tickets: <count> (phase0..<target>)
Subjects extracted: <count> (status: draft)
Worktree: <repo_root>

Drive this epic with one of:
  /orchestrate-epic <epic-id>        # autonomous, recommended
  bw ready                            # manual; pick the next unblocked ticket

After the epic closes, switch to /spec-led-development for ongoing maintenance.
```

If `bw` was unavailable during Phase 0, print the path to the markdown plan
that was written instead, and the same handoff guidance adapted for manual
execution.

---

## Resume — re-running the skill

The skill is idempotent at the file layer (`.spec/specs/*.spec.md` files are
never overwritten, only created if missing) and at the bw layer (existing
epics are reused, not duplicated). On every re-invocation:

1. Re-run **Phase 1 detection**. The `current_phase` will have advanced if
   prior stage tickets closed.
2. Look up prior bootstrap epics. Match on **both** title prefix and
   description body, since either can be renamed:
   ```bash
   bw list --grep "Adopt SpecLedEx" --all --json    # title match
   bw list --grep "Bootstrap epic produced by /spec-led-bootstrap" --all --json  # body match
   ```
   Union the results, sort by created-at desc, take the most recent.
3. Pre-flight: **consistency check between bw state and worktree state.**
   - Read the prior epic's `Target phase:` field and its closed-ticket
     count.
   - If bw says phase2 stage closed but `current_phase < phase2` in the
     current worktree (the prior work has not been merged into this
     branch yet), HALT and tell the user:
     > Prior bootstrap epic `<id>` reports phase2 work closed, but this
     > worktree's `.spec/` does not reflect it. Either merge the prior
     > work into this branch, or run from the worktree that owns it.
     > Refusing to re-do work that already exists elsewhere.

     Do not create new tickets, do not re-extract subjects.
4. Branch by epic status:

   **(a) Prior epic is open.**
   - If its `Target phase:` ≥ what the user wants now: print the epic id
     and the next unblocked ticket, exit. No new tickets.
   - If its `Target phase:` is lower than what the user wants now: create
     only the missing stage tickets (phase<prior+1>..phase<new_target>),
     wire them with `bw dep add` to the last existing stage ticket, and
     update the epic description's `Target phase:` field. Print the
     extended epic id and the next unblocked ticket.

   **(b) Prior epic is closed.**
   - Treat the closed epic as a baseline that has shipped. Detection's
     `current_phase` is the truth.
   - If the user wants to push further (`target_phase > current_phase`),
     create a NEW bootstrap epic for `phase<current+1>..phase<new_target>`.
     Its description must include a `Continues:` field linking the prior
     epic, e.g.:
     ```
     Continues: <prior-epic-id> (closed at phase2 on <date>)
     Target phase: phase4
     ```
   - If the user wants the same or lower target than what already
     shipped: print "Already at phase<N>; nothing to do." and exit.

5. **Subject extraction** runs only when `current_phase < phase1`, so a
   second invocation on a repo that already has subjects skips extraction
   entirely — no candidate list, no proposals, no spec writes.

### Renamed subjects

If detection finds `.spec/specs/<old-id>.spec.md` but the user has
renamed it to `<new-id>` since the prior run (look for matching
`spec-meta.id:` in any spec file before assuming absence), do not
re-extract the same cluster under the old id. When in doubt, list the
suspect candidates with a note "shares surface with existing subject
`<new-id>`" and let the user resolve.

---

## Self-check before reporting completion

- [ ] `mix.exs` includes `spec_led_ex` (or the user explicitly deferred the dep)
- [ ] `.spec/README.md`, `.spec/AGENTS.md`, `.spec/config.yml` exist
- [ ] If subjects were extracted: every `.spec/specs/<id>.spec.md` parses (`mix spec.validate` clean)
- [ ] One bw epic exists with a single-line `Target phase:` field in its description
- [ ] Stage tickets cover phase0..target_phase, in order, with dependencies wired
- [ ] Every stage ticket has all five sections: Advances, Deliverable, Verification, Out of Scope (files), Out of Scope (intent), Merge gate
- [ ] If subject extraction ran, the user saw the list before drafts were written
- [ ] Handoff summary printed with epic id and next-step command

---

## References

- [references/detection-matrix.md](references/detection-matrix.md) — full signal table, classification rules, and "what does this output mean" guide
- [references/adoption-phases.md](references/adoption-phases.md) — per-phase goal, gates added, escape hatches, success criteria
- [references/subject-extraction.md](references/subject-extraction.md) — heuristics, candidate scoring, presentation template, anti-patterns
- [references/task-templates.md](references/task-templates.md) — verbatim bw ticket bodies for each phase, with Allowed touches and Out of Scope globs
- [references/configurable-levers.md](references/configurable-levers.md) — every config knob in `.spec/config.yml` and when to flip it
- Upstream: `docs/adoption.md` and `docs/concepts.md` in the specled_ex repo
