# Adoption phases — the ladder

The seven phases (0 through 6) are documented authoritatively in
`docs/adoption.md` of the specled_ex repo. This page is the
**bootstrap-skill-side view**: what each phase costs, what it adds, what its
escape hatches look like, and what "done" means for a stage ticket.

| Phase | Gate added                                       | Reversible? | Recommended stop point          |
|-------|--------------------------------------------------|-------------|---------------------------------|
| 0     | `.spec/` exists; commands run                    | Yes         | Lightweight projects            |
| 1     | Subjects with `surface:` enable file-touch guard | Yes         | "I want some visibility"        |
| 2     | `api_boundary` hashes detect surface drift       | Yes         | Common stopping point           |
| 3     | Test tags enforce intent linkage                 | Yes         | After phase2 stabilizes         |
| 4     | Coverage triangulation closes the third side     | Yes         | Full-triangle targets           |
| 5     | `implementation` tier catches body drift         | Yes         | Refactor-heavy codebases only   |
| 6     | Severities → error; CI hard-fails on drift       | Hard to undo | Mature adoption                 |

The "recommended stop point" column is what `/spec-led-bootstrap` Phase 2
will suggest based on detected codebase shape.

## Phase 0 — Install and scaffold

**Adds:** dep, `.spec/README.md`, `.spec/AGENTS.md`, `.spec/config.yml`,
`.spec/decisions/README.md`, two template specs, the evidence-ledger
pre-push hook.

**Gate behavior:** `mix spec.check` runs but only the file-touch branch
guard can fire — and only against template subjects, so it is effectively
silent.

**Escape hatch:** delete `.spec/` — the dep does not run code at import; it
is opt-in via the mix tasks.

**Stage-ticket done criteria:**
- `mix spec.init` has run on the worktree
- `mix compile --warnings-as-errors` passes (catches dep version mismatch)
- `mix spec.check` exits 0 with no findings beyond `detector_unavailable`
- `.spec/AGENTS.md` references the project verification command (replace
  the `<PROJECT_VERIFICATION_COMMAND>` placeholder); on containerized
  repos, document the split loop (`<host_check_cmd>` on the host,
  `<container_verify_cmd>` in the container)
- `mix spec.evidence.install_hook` has run (pre-push hook installed, or
  the append-snippet printed for repos with an existing hook)
- The daily-loop guidance in `.spec/AGENTS.md` mentions `mix spec.sync`
  as the evidence reconciliation step (the pre-push hook runs it
  best-effort; a manual run recovers from skipped hooks)
- The two-armed decision rubric (durable/cross-cutting → ADR;
  ticket-local → `Spec-Drift:` trailer with a one-line reason) is written
  into `.spec/AGENTS.md` and `.spec/decisions/README.md`

## Phase 1 — Carve subjects (drafts)

**Adds:** N `.spec/specs/<id>.spec.md` files, each with `spec-meta.surface:`
pointing at real source files. Subjects are `status: draft`.

**Gate behavior:** `branch_guard_unmapped_change` becomes meaningful — PRs
touching files inside a subject's `surface:` get routed to that subject in
guidance. Drafts skip strict requirement checks, so missing verifications do
not block.

**Escape hatch:** flip subjects back to `status: archived`; the surface
mapping survives but does not gate.

**Stage-ticket done criteria:**
- For each accepted subject (from extraction Phase 3 or user-authored):
  - `.spec/specs/<id>.spec.md` exists and parses (`mix spec.validate`)
  - `spec-meta.id`, `kind`, `status: draft`, `summary`, `surface` all populated
  - At least one `spec-requirements` entry exists (placeholder OK)
- `mix spec.check` clean
- Stage commit message names the subjects added

**Fan-out:** if subject count > 3, this ticket is the parent for N child
tickets, one per subject. Children run in parallel under
`/orchestrate-epic`.

## Phase 2 — `api_boundary` bindings

**Adds:** `realized_by.api_boundary:` lists on every subject that wants
function-head drift detection. Subjects promote from `status: draft` to
`status: active`. The CI gate itself: this is the phase that installs
`mix spec.check --base <pr-base>` in CI and wires the `mix spec.review`
artifact — the PR-facing review surface is the most immediately visible
value of the whole adoption, so it lands with the first bindings, not at
lockdown.

**Gate behavior:** `branch_guard_realization_drift` fires when a bound MFA's
function head changes (arity, arg pattern, defaults).
`branch_guard_dangling_binding` fires when a bound MFA disappears.

**Escape hatch:** `Spec-Drift: branch_guard_realization_drift=info` git
trailer downgrades for one PR. `:off` in
`branch_guard.severities.branch_guard_realization_drift` disables workspace-wide.

**Authoring step:** run `mix spec.suggest_binding` to print proposals; paste
each block into the subject's `spec-meta`. Do not use `--write` — it does
not exist (intentional).

**Stage-ticket done criteria:**
- Every subject from phase1 has a `realized_by.api_boundary:` block with at
  least the public functions declared
- All subjects flipped to `status: active`
- No placeholder requirements ("Bootstrap draft — …") survive promotion to
  `status: active` — each is either refined into a real behavioral claim
  or deleted
- `mix spec.check --base origin/main` clean
- First clean check committed `.spec/realization_hashes.json` so subsequent
  runs have baseline hashes to compare against
- CI runs `mix spec.check --base <pr-base>` on pull requests (severities
  still warning-level, so it reports without hard-failing)
- CI renders `mix spec.review` and uploads/deploys the HTML artifact —
  start from the scaffolded workflow template
  (`deps/spec_led_ex/priv/spec_init/workflows/spec_review.yml.eex`, copied
  to `.github/workflows/spec-review.yml`)

**Security caveat (scaffolded workflow).** The scaffolded template builds
untrusted PR code in the same job that holds a write-scoped token and deploys
the artifact. On a public repo that is a privilege-escalation surface: split
the render (read-only, runs PR code) from the deploy/comment job (write token,
no PR-code execution) and hand off via an uploaded artifact, or keep the render
job read-only until the template is hardened. Tracked in follow-up ticket
`specled_-3q1`.
- If the repo uses the evidence ledger with a shared remote, CI fetches
  the `spec-evidence` ref read-only before checking. Caveat: attestations
  in that ref are unauthenticated — CI may consume them for reporting but
  must not treat them as proof that verification commands ran

**Fan-out:** same shape as phase1. One child ticket per subject is
recommended over a single sweep, because bindings need per-subject judgment
about what is "API" vs "internal".

## Phase 3 — Test tags

**Adds:** `test_tags.enabled: true` in `.spec/config.yml` (start with
`enforcement: warning`). Tests get `@tag spec: "<requirement.id>"`.

**Gate behavior:** `branch_guard_requirement_without_test_tag` warns when a
new `must` requirement on a subject covered by a `tagged_tests` verification
has no backing tag. Its validator-side sibling `requirement_without_test_tag`
(no `branch_guard_` prefix) fires on **every** untagged `must`, not just new
ones — expect a backlog-sized count from `mix spec.validate` on day one of
phase3; only the branch-side code gates PRs.

**Escape hatch:** `@tag spec_triangulation: :indirect` for integration tests
that tag one subject while legitimately exercising others. The whole
scanner can be disabled with `test_tags.enabled: false`.

**Stage-ticket done criteria:**
- `test_tags.enabled: true, enforcement: warning` in `.spec/config.yml`
- At least one test per active subject carries an `@tag spec:` (token gesture)
- At least one subject has a `kind: tagged_tests` verification block
- `mix spec.check` runs the tag scanner without parse errors
- No backlog mandate — tagging is opportunistic from here

## Phase 4 — Coverage triangulation

**Adds:** `SpecLedEx.Coverage.Formatter` in `test/test_helper.exs`;
`mix spec.cover.test` in CI; the third side of the triangle.

**Gate behavior:** `branch_guard_untested_realization`,
`branch_guard_untethered_test`, `branch_guard_underspecified_realization`
all come online.

**Escape hatch:** delete the formatter from `test_helper.exs` and the
detectors degrade to `detector_unavailable :no_coverage_artifact`.

**Stage-ticket done criteria:**
- `test_helper.exs` includes the formatter
- One green local run of `mix spec.cover.test` produces
  `.spec/_coverage/per_test.coverdata` (commit if your repo wants to;
  usually `.gitignore` it)
- CI runs `mix spec.cover.test` before `mix spec.check`
- `mix spec.triangle --all` runs cleanly (it diagnoses; it does not gate)

**Skip-permanently option:** if the team decides triangulation is not worth
the test-suite cost, write `:off` for the three new finding codes and skip
this ticket entirely. The bootstrap epic accommodates this opt-out.

## Phase 5 — `implementation` tier

**Adds:** `realized_by.implementation:` lists for subjects whose internal
call closure should be guarded.

**Gate behavior:** behavior drift inside a subject's code surfaces as
`branch_guard_realization_drift` on the implementation tier. The compile
tracer captures call edges; closure walking stops at subject boundaries.

**Escape hatch:** remove the `implementation:` field from a subject; the
tier silently disables for that subject.

**When to skip this phase entirely:** if the codebase rarely sees semantic
refactors (most churn is new features), the tracer cost outweighs the
signal. The bootstrap skill recommends skip unless the user explicitly
asks for it.

**Stage-ticket done criteria:**
- The subjects the user nominated have `realized_by.implementation:` blocks
- `mix compile` runs (so the tracer fires) and `mix spec.check` is clean
- Per-subject hash baselines committed in `.spec/realization_hashes.json`

## Phase 6 — Lock down

**Adds:** severity bumps in `.spec/config.yml`:

```yaml
test_tags:
  enforcement: error

guardrails:
  severities:
    append_only/requirement_deleted: error
    append_only/scenario_regression: error
    overlap/duplicate_covers: error

branch_guard:
  severities:
    branch_guard_dangling_binding: error
    branch_guard_realization_drift: error
```

**Gate behavior:** CI hard-fails on the locked codes. `Spec-Drift:` trailers
become the explicit exception path.

**Escape hatch:** revert the severity bumps. This is reversible at the
config level, but socially expensive — landing phase6 is a commitment.

**Stage-ticket done criteria:**
- Severities raised
- Two consecutive PRs land without any `Spec-Drift:` trailer (proof the
  team can work under the new gates without escape hatches)
- The `mix spec.check --base <pr-base>` CI step installed in phase2 is
  moved to be the rightmost gate in the pipeline (so PRs fail clearly on
  drift rather than getting blamed on a flaky earlier step)

---

## What "done" looks like for the whole bootstrap epic

The epic closes when:

1. All stage tickets up to `target_phase` are closed.
2. `mix spec.check` is green on the bootstrap branch.
3. The bootstrap branch has been merged to main (this is the orchestrator's
   final push to a human; the skill never pushes itself).
4. `/spec-led-development` is documented somewhere in the project (usually
   `.spec/AGENTS.md` or a CLAUDE.md addition) as the ongoing-maintenance
   skill.
5. If `target_phase < phase6`, a deferred **graduation review** ticket
   exists (`bw defer`, ~4 weeks out). See the "Graduation review" section
   of [task-templates.md](task-templates.md) for the ticket body and its
   rationale.

Once those four hold, future spec work flows through `/spec-led-development`
and `/distill` rather than this skill.
