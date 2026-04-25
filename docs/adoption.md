# Adoption

<!-- covers: specled.package.adoption_guide -->

How to land Spec Led Development in a project. There are two paths — greenfield
(starting from `mix new`) and brownfield (bolting onto an existing tree). The
two paths share the same destination but reach it differently: greenfield turns
on every gate from day one, brownfield phases gates in over multiple PRs while
keeping the build green.

## What you are opting into

A subject spec under `.spec/specs/<subject>.spec.md` claims behavior. Three
things attach to that claim:

1. **`realized_by:`** — typed pointers from the subject (or one requirement) to
   the MFAs that realize it. Tiers: `api_boundary`, `implementation`,
   `expanded_behavior`, `use`, `typespecs`. You opt into them in that order.
2. **`@tag spec: "<requirement.id>"`** on ExUnit tests — the test claims it
   covers a requirement. Verified statically by `SpecLedEx.TagScanner` (no
   compilation, no test run).
3. **Per-test coverage** captured by `mix spec.cover.test` — the actual MFAs
   each test executed, written to `.spec/_coverage/per_test.coverdata`.

`mix spec.check` cross-checks all three. Each side degrades to a single
`detector_unavailable` finding when its inputs are missing rather than failing
the build, which is what makes incremental adoption safe.

The full set of branch-guard codes you eventually want green:

| Code                                          | What disagrees                                          |
|-----------------------------------------------|---------------------------------------------------------|
| `branch_guard_realization_drift`              | Bound MFA hash changed without the spec acknowledging   |
| `branch_guard_dangling_binding`               | `realized_by:` names an MFA the compiler cannot resolve |
| `branch_guard_untested_realization`           | Requirement has a closure but no test reaches any MFA   |
| `branch_guard_untethered_test`                | Test's `@tag spec:` names subject A but it executes B   |
| `branch_guard_underspecified_realization`     | Test reaches subject A's MFAs but carries no `@tag`     |
| `branch_guard_requirement_without_test_tag`   | New `must` requirement has no backing `@tag spec:`      |
| `branch_guard_unmapped_change`                | Changed file does not belong to any subject's surface   |
| `append_only/*`                               | Spec corpus regressed (deletion, downgrade, etc.)       |
| `overlap/*`                                   | Two requirements/scenarios collide within a subject     |

---

## Greenfield

You are at `mix new my_app` and want the triangle from day one. Six steps.

### 1. Add the dependency and scaffold

```elixir
# mix.exs
{:spec_led_ex, github: "...", only: [:dev, :test], runtime: false}
```

```bash
mix deps.get
mix spec.init
```

`spec.init` writes `.spec/README.md`, `.spec/AGENTS.md`,
`.spec/decisions/README.md`, and `.spec/config.yml`. In an interactive run it
also offers to scaffold a local Skill for agents working on the repo.

### 2. Turn on test-tag scanning immediately

Edit the scaffolded `.spec/config.yml`:

```yaml
test_tags:
  enabled: true
  paths:
    - test
  enforcement: warning   # graduate to error once coverage closes
```

Greenfield projects have no legacy untagged tests, so there is no reason to
delay enabling the scanner. Keep `enforcement: warning` for the first week or
two while you build the muscle memory of writing the `@tag` next to the test.

### 3. Write your first subject with `realized_by`

Create `.spec/specs/invoice_numbering.spec.md`:

````markdown
# Invoice Numbering

Issues monotonically increasing invoice numbers per tenant.

```yaml spec-meta
id: billing.invoice_numbering
kind: module
status: active
summary: Per-tenant monotonically increasing invoice number issuer.
realized_by:
  api_boundary:
    - "MyApp.Billing.InvoiceNumbering.next/1"
    - "MyApp.Billing.InvoiceNumbering.peek/1"
  implementation:
    - "MyApp.Billing.InvoiceNumbering.next/1"
```

```yaml spec-requirements
- id: billing.invoice_numbering.monotonic
  statement: next/1 shall return strictly increasing integers per tenant.
  priority: must
  stability: evolving
```

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - billing.invoice_numbering.monotonic
```
````

Tag the test:

```elixir
@tag spec: "billing.invoice_numbering.monotonic"
test "issues strictly increasing numbers" do
  ...
end
```

Run `mix spec.check`. Both `realized_by.api_boundary` (function-head hashes)
and `tagged_tests` (intent linkage) gate immediately.

### 4. Wire per-test coverage into the test helper

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, SpecLedEx.Coverage.Formatter])
```

Run `mix spec.cover.test` to produce `.spec/_coverage/per_test.coverdata`. This
unlocks `branch_guard_untested_realization`, `branch_guard_untethered_test`,
and `branch_guard_underspecified_realization`. Inspect a subject directly:

```bash
mix spec.triangle billing.invoice_numbering
```

### 5. Wire CI

```yaml
# .github/workflows/spec.yml
- run: mix spec.cover.test
- run: mix spec.check --base origin/main
```

`scripts/check_specs.sh` in this repo is the reference shape.

### 6. Graduate severities

Once the triangle is closed for every active subject and the gate is green
without any `Spec-Drift:` overrides:

```yaml
# .spec/config.yml
test_tags:
  enforcement: error

guardrails:
  severities:
    append_only/requirement_deleted: error
    append_only/modal_downgraded: error
    overlap/duplicate_covers: error

branch_guard:
  severities:
    branch_guard_dangling_binding: error
    branch_guard_realization_drift: error
```

You are done. The triangle is closed and CI enforces it.

---

## Brownfield

You have an existing project with code, tests, and probably no `.spec/`. The
goal is the same destination, but each phase ships independently — every PR
keeps the build green and adds one more constraint. Plan on six PRs over a few
weeks, not a single big-bang adoption.

### Phase 0 — Instrument without enforcing

```bash
mix spec.init
mix spec.prime --base HEAD
mix spec.status
```

`mix spec.status` is the brownfield-specific tool: it summarizes which source,
guide, and test files the existing specs do not yet cover. Use it to scope the
remaining phases. At this point `mix spec.check` runs but only file-touch
guidance fires; no triangle exists yet.

**Commit and merge.** This PR adds `.spec/` and `config.yml` only.

### Phase 1 — Carve subjects with `surface:`, no bindings yet

For each module cluster you want to govern, add a subject spec. Use
`spec-meta.surface:` to point at the existing files; do **not** add
`realized_by:` yet.

```yaml spec-meta
id: billing.invoice_numbering
status: draft       # use draft until requirements are ground-truth
summary: ...
surface:
  - lib/my_app/billing/invoice_numbering.ex
  - test/my_app/billing/invoice_numbering_test.exs
```

The file-touch branch guard now works: editing those files routes guidance
back to the subject. `mix spec.check` is still cheap because no realization
tier is computing hashes.

**Commit and merge.** Repeat per subject cluster. There is no requirement to
cover the whole tree at once — uncovered files surface as
`branch_guard_unmapped_change` warnings on the PRs that touch them, which is
the natural prompt to carve another subject.

### Phase 2 — `api_boundary` tier

For the subjects you want to lock down first (start with the most-edited
modules), seed bindings:

```bash
mix spec.suggest_binding
```

This reads each subject's `surface:` and prints a proposed
`realized_by.api_boundary:` block per subject with no binding. It is
proposal-only — no `--write` flag — so you (or an agent) paste each block into
the matching `spec-meta`. Flip the subject from `status: draft` to
`status: active` in the same edit.

`mix spec.check` now hashes function heads, stores the hash on the next clean
run, and on the run after that emits `branch_guard_realization_drift` when
hashes disagree and `branch_guard_dangling_binding` when an MFA disappears.

**Default severities are forgiving.** If an early adopter PR is loud, raise
`branch_guard.severities.branch_guard_realization_drift: info` for one PR via
config or use a per-commit `Spec-Drift:` trailer. Do not delete the binding to
quiet the noise.

### Phase 3 — Tag tests as you touch them

You already enabled `test_tags: enabled: true, enforcement: warning` in
Phase 0. Now start tagging:

```elixir
@tag spec: "billing.invoice_numbering.monotonic"
test "..." do
```

`requirement_without_test_tag` only fires on `must`-priority requirements that
are covered by a `tagged_tests` verification on their owning subject. This is
a deliberate narrowing — requirements verified only by `source_file` or
`command` will not nag you for tags. The result is that you can tag opportunistically without a backlog burning down.

When a subject is fully tagged, replace its per-spec `mix test <files>`
verification with `kind: tagged_tests`:

```yaml spec-verification
- kind: tagged_tests
  execute: true
  covers:
    - billing.invoice_numbering.monotonic
```

Aggregation across all subjects collapses to one `mix test --only spec:...`
invocation per `spec.check` run, which is materially cheaper than N cold BEAM
boots.

### Phase 4 — Coverage triangulation

Add the formatter to `test/test_helper.exs` and start running
`mix spec.cover.test` in CI alongside `mix spec.check`:

```elixir
ExUnit.start(formatters: [ExUnit.CLIFormatter, SpecLedEx.Coverage.Formatter])
```

```bash
mix spec.cover.test
mix spec.check --base origin/main
```

Without the coverage artifact, triangulation emits exactly one
`detector_unavailable` finding (`reason: :no_coverage_artifact`) and falls
silent. With it, the three new findings come online:

- `branch_guard_untested_realization` — closure exists, no test reaches it
- `branch_guard_untethered_test` — `@tag spec:` claims A but execution hits B
- `branch_guard_underspecified_realization` — silent execution coverage no
  requirement claims

For intentionally indirect coverage (an integration test that legitimately
tags one subject while exercising several), use the per-test opt-out:

```elixir
@tag spec: "billing.invoice_numbering.monotonic"
@tag spec_triangulation: :indirect
test "...", do: ...
```

`mix spec.triangle <subject.id>` (or `mix spec.triangle --all`) prints the
per-requirement diagnostic so you can read the disagreement before triaging.

### Phase 5 — `implementation` tier (closure)

Add `realized_by.implementation:` for subjects whose internal call closure you
want guarded against silent drift. The compile tracer captures call edges
during `mix compile`; closure walking stops at subject boundaries and emits
hash-references rather than inlining, so a downstream subject's hash flip
ripples cleanly upstream without spurious cross-subject drift.

The payoff: cosmetic refactors inside the closure (variable renames, body
reflows, function reordering) do not produce drift findings. The cost: a
compile tracer running on every build. Skip this tier indefinitely if your
team's churn pattern is mostly new-feature work rather than refactor; it pays
back when you start moving function bodies between modules.

### Phase 6 — Lock down

Same as greenfield step 6: graduate `enforcement: error`, raise severities on
the codes you trust, leave `Spec-Drift:` trailers as the exception path.

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
    branch_guard_untested_realization: warning   # keep at warning a while longer
```

---

## Escape hatches

These let you keep moving when a finding is wrong, premature, or scoped to one
PR. Reach for them deliberately — every escape hatch is a small honesty debt.

| Hatch                                            | Scope                          | When to use |
|--------------------------------------------------|--------------------------------|-------------|
| `:off` in `branch_guard.severities` or `guardrails.severities` | Workspace, durable | The finding code does not apply to your project (e.g. `umbrella_unsupported`). |
| `:info` in either severity map                   | Workspace, durable             | You want the finding visible in `state.json` and under `--verbose` but not in default output. |
| `Spec-Drift: <code>=<severity>` git trailer      | One PR (any commit in the range) | Surgical, one-off downgrade for a specific PR. Cannot revive `:off`. |
| `Spec-Drift: refactor`/`docs_only`/`test_only`   | One PR                         | Common shorthand for whole classes of low-risk changes. |
| `mix spec.check --no-run-commands`               | One invocation                 | Local fast loop; CI should always run commands. |
| `mix spec.check --verbose` / `SPECLED_SHOW_INFO=1` | One invocation                 | Surface `:info` findings during debugging. |
| `status: draft` on a subject                     | Subject                        | Spec is incomplete; verifier skips strict checks. Do not ship `draft` to main. |
| `@tag spec_triangulation: :indirect`             | One test                       | Test deliberately exercises subjects other than the one it tags. |
| `detector_unavailable`                           | Automatic                      | Not a hatch you set — a tier emits this when its inputs are missing, and the rest of the gate proceeds. |

---

## Decision points

A few choices that come up often enough to call out:

- **Skip the `implementation` tier indefinitely.** `api_boundary` catches most
  surface drift cheaply. The `implementation` tier exists for projects whose
  pain is silent semantic refactors; if your churn is mostly new-feature work,
  the closure walk is overhead you may never recoup.
- **Skip coverage triangulation indefinitely.** `tagged_tests` alone gives
  intent linkage and the cheap branch-guard check
  (`requirement_without_test_tag`). Triangulation costs a serialized
  `mix test --cover` run; teams that already run a slow test suite may decide
  the marginal signal is not worth it.
- **Umbrella projects.** v1 emits `detector_unavailable :umbrella_unsupported`
  for the realization tiers; tagged tests, ADR governance, overlap detection,
  and append-only checks all still work. v1.1 will close this gap.
- **`mix spec.suggest_binding` for brownfield.** It only proposes
  `api_boundary` from `surface:` `lib/*.ex` entries. For `implementation`,
  `expanded_behavior`, `use`, and `typespecs` tiers, you author by hand (or
  let an agent author from the implementation).

---

## What a session looks like at each phase

Brownfield Phase 1 (subjects only):

```bash
mix spec.prime --base HEAD          # orient
# ... edit code ...
mix spec.next                       # "needs subject updates: billing.invoice_numbering"
# ... update the subject ...
mix spec.check --base origin/main   # green
```

Brownfield Phase 4+ (full triangle):

```bash
mix spec.prime --base HEAD
# ... edit code ...
mix spec.next                       # "ready for check"
# ... add @tag spec: ... to the new test ...
mix spec.cover.test                 # capture per-test coverage
mix spec.check --base origin/main   # may emit untested_realization
mix spec.triangle billing.invoice_numbering   # diagnose the disagreement
# ... fix tag, binding, or test ...
mix spec.check --base origin/main   # green
```

The core loop never grows past four commands (`prime`, `next`,
`cover.test`, `check`). Triangulation does not add steps — it adds
diagnostics on the same `check` invocation, with `spec.triangle` available
when you want to inspect one subject in isolation.
