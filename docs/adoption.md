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
3. **Coverage** captured by `mix spec.cover.test` — one command, no wiring
   for the default aggregate lane. By default it ingests an aggregate run
   (which MFAs were executed by *any* test, written to
   `.spec/_coverage/per_test.coverdata`); an opt-in `--per-test` flag adds
   exclusive per-test attribution on top (exact within disclosed chained windows
   when the boundary hook is wired — Phase 4b). See
   [`docs/coverage.md`](coverage.md) for the full contract.

`mix spec.check` cross-checks the first two sides — `realized_by:` hash
drift and `@tag spec:` presence. When a realization detector's
prerequisites are missing, the affected tiers degrade to
`detector_unavailable` findings instead of failing the build — one finding
per enabled tier (e.g. reason `umbrella_unsupported`), or one per affected
module for `debug_info_stripped` — which is what makes incremental adoption
safe. The `@tag spec:` side has no degrade path: with test-tag scanning
disabled, that check simply does not run. Coverage
triangulation (the third side) is a separate, read-only diagnostic tier:
`mix spec.check` never runs it and never gates on it, regardless of
`.spec/config.yml`. Read triangulation from `mix spec.triangle` or `mix
spec.review`'s Coverage tab instead.

The full set of branch-guard codes `mix spec.check` gates on:

| Code                                          | What disagrees                                           |
|------------------------------------------------|-----------------------------------------------------------|
| `branch_guard_realization_drift`              | Bound MFA hash changed without the spec acknowledging    |
| `branch_guard_dangling_binding`               | `realized_by:` names an MFA the compiler cannot resolve   |
| `branch_guard_requirement_without_test_tag`   | New `must` requirement has no backing `@tag spec:`        |
| `branch_guard_unmapped_change`                | Changed file does not belong to any subject's surface     |
| `branch_guard_missing_subject_update`         | Changed file sits in a subject's surface but that subject's spec did not change |
| `branch_guard_missing_decision_update`        | Cross-cutting change spans multiple subjects with no decision file change |
| `branch_guard_realization_unknown_tier`       | `realization.enabled_tiers` in `.spec/config.yml` names a tier that does not exist |
| `append_only/*`                               | Spec corpus regressed (deletion, downgrade, etc.)         |
| `overlap/*`                                   | Two requirements/scenarios collide within a subject       |

Coverage triangulation is diagnostic-only and never part of the
`mix spec.check` gate, even though its codes carry the same `branch_guard_`
prefix — `mix spec.check` does not emit them, and their severities are not
read from `.spec/config.yml`. Read them from `mix spec.triangle` or
`mix spec.review`'s Coverage tab:

| Code                                          | What disagrees                                             |
|------------------------------------------------|-------------------------------------------------------------|
| `branch_guard_untested_realization`           | Requirement has a closure but no test reaches any MFA       |
| `branch_guard_untethered_test`                | Test's `@tag spec:` names subject A but it executes B (per-test artifacts only) |
| `branch_guard_underspecified_realization`     | Test reaches subject A's MFAs but carries no `@tag`          |

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

`spec.init` writes `.spec/README.md`, `.spec/AGENTS.md`, `.spec/config.yml`,
`.spec/decisions/README.md`, and two starter subjects —
`.spec/specs/spec_system.spec.md` and `.spec/specs/package.spec.md`. In an
interactive run it also offers to scaffold a local Skill for agents working on
the repo.

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

### 4. Capture coverage

Setup is one command:

```bash
mix spec.cover.test
```

Never add `SpecLedEx.Coverage.Formatter` anywhere — it is inert unless the
task arms it (see [`docs/coverage.md`](coverage.md)). This produces
`.spec/_coverage/per_test.coverdata` and unlocks the triangulation
diagnostics on `mix spec.triangle` and `mix spec.review`'s Coverage tab:
`branch_guard_untested_realization`, `branch_guard_untethered_test`, and
`branch_guard_underspecified_realization`. `mix spec.check` itself never
runs triangulation. Inspect a subject directly:

```bash
mix spec.triangle billing.invoice_numbering
```

### 5. Wire CI

```yaml
# .github/workflows/spec.yml
- run: git fetch origin +refs/heads/spec-evidence:refs/remotes/origin/spec-evidence || true
- run: mix spec.cover.test
- run: mix spec.check --base origin/main
```

`scripts/check_specs.sh` in this repo is the reference shape.
The `spec-evidence` fetch is read-only setup so the checker can see prior
attestations when they exist. Evidence is an unauthenticated attestation:
any repo writer can mint it, so it is forbidden as a merge-gate or pass/fail
input. A fresh local check result is what gates the build. The verdict is the last stdout line starting with `spec.check result=` — not `validate status=…`. A non-zero exit means failure even if no verdict line appears.

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
    append_only/must_downgraded: error
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

**Wire CI here.** This is the phase that installs `mix spec.check --base
<pr-base>` in CI and renders the `mix spec.review` artifact — the PR-facing
review surface lands with the first bindings, not at lockdown. Severities are
still warning-level, so the gate reports without hard-failing. Later phases
(coverage, lockdown) add steps to this same workflow rather than introducing
it. The verdict is the last stdout line starting with `spec.check result=` — not `validate status=…`. A non-zero exit means failure even if no verdict line appears.

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

Aggregation across all subjects collapses to one `mix test` invocation per
`spec.check` run — listing the scanner-resolved test files that back the
tagged ids, not `--only spec:` filters (see the
`tagged_tests_file_selectors` decision; file selectors keep list-valued
`@tag spec:` and inherited `@moduletag`/`@describetag` entries executable) —
which is materially cheaper than N cold BEAM boots.

### Phase 4a — Aggregate coverage (zero wiring)

No wiring step: run `mix spec.cover.test` (in CI or locally) and read the
result with `mix spec.triangle` or `mix spec.review`'s Coverage tab. `mix
spec.check` never runs triangulation and stays exactly as fast whether or
not this phase is adopted — do not add it to the `spec.check` step.

```bash
mix spec.cover.test
mix spec.triangle --all
```

Without the coverage artifact, `mix spec.triangle`/`mix spec.review` emit
one `detector_unavailable` finding (`reason: :no_coverage_artifact`) per
selected subject — so `mix spec.triangle --all` prints one per indexed
subject — and fall silent. With the artifact, the three diagnostics come
online:

- `branch_guard_untested_realization` — closure exists, no test reaches it
- `branch_guard_untethered_test` — `@tag spec:` claims A but execution hits B
  (needs a `--per-test` artifact; see Phase 4b and
  [`docs/coverage.md`](coverage.md))
- `branch_guard_underspecified_realization` — silent execution coverage no
  requirement claims

These carry the `branch_guard_` prefix by naming convention only — they are
not part of the `mix spec.check` gate, and `.spec/config.yml` severities do
not affect them; `mix spec.triangle`/`mix spec.review` print them
unconditionally.

For intentionally indirect coverage (an integration test that legitimately
tags one subject while exercising several), use the per-test opt-out:

```elixir
@tag spec: "billing.invoice_numbering.monotonic"
@tag spec_triangulation: :indirect
test "...", do: ...
```

`mix spec.triangle <subject.id>` (or `mix spec.triangle --all`) prints the
per-requirement diagnostic so you can read the disagreement before triaging.

### Phase 4b — Per-test attribution (opt-in)

Phase 4a is enough for file-level and subject-level triangulation. Opt into
Phase 4b only when you want exclusive per-test attribution
(`branch_guard_untethered_test` and per-test "Reached by" rows).

**Wiring cost.** Add one setup line per case template (2–4 places in a
typical app). In a Phoenix-style app case template:

```elixir
setup {SpecLedEx.Coverage, :per_test_boundary}
```

For bare `ExUnit.Case` modules, prefer the package case:

```elixir
defmodule MyApp.SomeTest do
  use SpecLedEx.Case, async: false

  test "example" do
    assert true
  end
end
```

The hook no-ops unless `mix spec.cover.test --per-test` has armed it, so
it is safe to leave wired under plain `mix test`. Full contract:
["Wiring the per-test boundary hook"](coverage.md#wiring-the-per-test-boundary-hook)
in [`docs/coverage.md`](coverage.md).

**Claim.** Hooked tests are **exact within chained windows**. The first hooked
test takes an initial head snapshot; every `on_exit` takes a tail snapshot that
`ExUnit.Runner` awaits before advancing and that tail becomes the next test's
head. The windows are disjoint, but after the first hooked test a window also
contains everything since the prior hooked tail: serialized runner /
`setup_all` work and any intervening unhooked tests. A process a test spawns
that outlives its tail can likewise increment shared `:cover`/native counters
in a later window or the unattributed remainder. Neither source of leakage is
detected at runtime.

**Unhooked modules degrade, never fail.** Run `--per-test` without wiring
and every unhooked module still contributes coverage to the aggregate
remainder; the envelope is `degraded: true` with `meta.unhooked_modules`
listing them; stderr prints one remediation notice per module, e.g.:

```
[SpecLedEx.Coverage.Formatter] 3 tests in MyApp.FooTest ran without the per-test boundary hook; their coverage was folded into the run's aggregate remainder and the artifact is marked degraded. Add to the case (or its case template): setup {SpecLedEx.Coverage, :per_test_boundary} — or use SpecLedEx.Case for bare ExUnit.Case modules.
```

Capture with the opt-in flag:

```bash
mix spec.cover.test --per-test
```

### Phase 5 — `implementation` tier (closure)

Add `realized_by.implementation:` for subjects whose internal call closure you
want guarded against silent drift. The bindings alone do nothing: the
`implementation` tier is excluded from the default tier set, so `mix
spec.check` skips it until `.spec/config.yml` opts in explicitly:

```yaml
realization:
  enabled_tiers: [api_boundary, implementation]
```

With the tier enabled, the compile tracer captures call edges
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
```

`branch_guard_untested_realization` and its two triangulation siblings are
not listed here because `.spec/config.yml`'s `branch_guard.severities` does
not affect them at all — they are diagnostics `mix spec.triangle`/`mix
spec.review` print at a fixed severity, never part of the `mix spec.check`
gate this block configures.

---

## Escape hatches

These let you keep moving when a finding is wrong, premature, or scoped to one
PR. Reach for them deliberately — every escape hatch is a small honesty debt.

| Hatch                                            | Scope                          | When to use |
|--------------------------------------------------|--------------------------------|-------------|
| `:off` in `branch_guard.severities` or `guardrails.severities` | Workspace, durable | The finding code does not apply to your project (e.g. the realization codes on an umbrella project, where the tiers only degrade to `detector_unavailable` with reason `umbrella_unsupported` — a reason field, not an overridable code). |
| `:info` in either severity map                   | Workspace, durable             | You want the finding visible in local evidence and under `--verbose` but not in default output. |
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
  (`requirement_without_test_tag`). Phase 4a (`mix spec.cover.test`
  aggregate) is async-safe and O(codebase) — no serialized run and no
  wiring — but it is still one more command and artifact to keep fresh.
  Phase 4b (`--per-test`) additionally costs the boundary wiring (one setup
  line per case template, or `SpecLedEx.Case` for bare modules) and forces
  serialization; the unhooked remediation notice teaches that wiring lazily
  when you run `--per-test` without it. Teams that do not want either cost
  simply never run `mix spec.cover.test`/`mix spec.triangle`; there is no
  config lever to silence the diagnostics because they never run without
  their input.
- **Umbrella projects.** The realization tiers emit `detector_unavailable` with
  reason `umbrella_unsupported`; tagged tests, ADR governance, overlap
  detection, and append-only checks all still work. Do not gate this on a
  version string — probe the installed dep's behavior: run `mix spec.check`
  once and look for a `detector_unavailable` finding whose reason is
  `umbrella_unsupported`. If it degrades cleanly, cap the target phase below the
  realization tiers and write explicit `off` opt-outs for those codes.
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
mix spec.cover.test                 # capture coverage (aggregate by default)
mix spec.check --base origin/main   # green — spec.check never runs triangulation
mix spec.triangle billing.invoice_numbering   # diagnose coverage disagreement
# ... fix tag, binding, or test ...
mix spec.triangle billing.invoice_numbering   # confirm the disagreement is gone
```

The core loop never grows past four commands (`prime`, `next`,
`cover.test`, `check`); `spec.check`'s own exit status never depends on
triangulation. `spec.triangle` is a separate, always-available diagnostic
step for when you want to inspect one subject's coverage disagreement in
isolation — run it whenever you want the signal, not because `spec.check`
demands it. The verdict is the last stdout line starting with `spec.check result=` — not `validate status=…`. A non-zero exit means failure even if no verdict line appears.

Workflow tooling may call `mix spec.sync` at natural push points, such as a
pre-push hook or release script, to reconcile local evidence before publishing.
Calling `mix spec.sync` from both the tool and the installed hook is a no-op by
construction when no new evidence was written.
