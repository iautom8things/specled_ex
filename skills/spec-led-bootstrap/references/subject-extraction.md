# Subject extraction — the worst-case path

When `current_phase < phase1`, no specs exist and the bootstrap skill must
propose subject boundaries from existing code. This is the most judgment-heavy
step in the whole flow. Do it carefully — every accepted subject becomes a
boundary the team will live with for months.

The premise: **specs are about behavior, not modules.** A good subject names
*what the code does*; the modules listed in `surface:` are how that behavior
is currently implemented. Multiple modules can realize one subject; one
module can occasionally belong to two subjects (rare, prefer to split).

## Pipeline

1. **Cluster** — generate candidates from heuristics
2. **Score and filter** — drop weak candidates, merge duplicates
3. **Present** — show the user, let them accept / defer / merge / split
4. **Draft** — write `.spec/specs/<id>.spec.md` for accepted candidates

Phase 3 of the bootstrap skill follows this pipeline literally.

## Clustering heuristics

Apply in order; a module that matches a higher-priority heuristic stays with
that cluster and is removed from later candidate pools.

### H1 — Phoenix contexts

For Phoenix apps (signal: `lib/<app>_web/`), each directory under
`lib/<app>/` whose name matches `^[a-z_]+$` and contains both a top-level
module (e.g. `lib/myapp/billing.ex`) and child modules
(`lib/myapp/billing/*.ex`) is one cluster.

```
candidate_id:   <app>.<context>
surface:        lib/<app>/<context>.ex
                lib/<app>/<context>/**/*.ex
                test/<app>/<context>/**/*_test.exs
rationale:      Phoenix context boundary
```

Phoenix contexts are the strongest signal — accept by default unless the
user objects.

### H2 — Behaviour-defining modules

Any module containing `@callback` at module scope. The module *is* the
subject; its callbacks define the surface. The implementations of that
behaviour are NOT included in the subject — they belong to whatever cluster
their module belongs to.

```
candidate_id:   <inferred_namespace>.<behaviour_slug>
surface:        lib/<path>/<behaviour>.ex
rationale:      Behaviour module — N callbacks define the contract
```

`<inferred_namespace>` is the lib subdirectory: a module at
`lib/myapp/storage/adapter.ex` becomes `myapp.storage_adapter`.

### H3 — GenServer / Supervisor clusters

A `use GenServer` module plus its public client functions (typically in the
same file or a thin wrapper module) is a candidate. Application supervisor
trees (`use Application` or `use Supervisor`) are candidates with their
direct children.

```
candidate_id:   <inferred_namespace>.<genserver_slug>
surface:        lib/<path>/<genserver>.ex
                lib/<path>/<genserver>/**/*.ex   # state, helpers
rationale:      Stateful service — public API is the contract
```

### H4 — Top-level lib directories (fallback for non-Phoenix apps)

Each directory directly under `lib/<app>/` at depth 2, when it contains
≥2 modules and none of those modules have already been claimed by H1–H3.

```
candidate_id:   <app>.<dirname>
surface:        lib/<app>/<dirname>/**/*.ex
                test/<app>/<dirname>/**/*_test.exs
rationale:      Lib subdirectory cluster
```

### H5 — Solo public APIs

A module under `lib/<app>/<file>.ex` (depth 2, no children) with ≥5
public functions AND ≥3 incoming calls from sibling modules. Often a
"helpers" module that is really doing more than it lets on.

```
candidate_id:   <app>.<modname>
surface:        lib/<app>/<modname>.ex
rationale:      Public API surface — N exports, M internal callers
```

## Scoring

For each candidate compute:

| Factor                                                   | Weight |
|----------------------------------------------------------|--------|
| Source file count (capped at 10)                         | +1 per file (max +10) |
| Has a corresponding `test/.../<id>_test.exs` file        | +5     |
| Has a corresponding guide or doc page                    | +3     |
| Heuristic priority (H1 > H2 > H3 > H4 > H5)              | +5, +4, +3, +2, +1 |
| <2 source files                                          | DROP   |
| Surface overlaps >50% with a higher-scored candidate     | MERGE into higher-scored |
| Surface overlaps 1–50% with another candidate            | flag for user review |

The result is a sorted list, highest score first.

## Filtering

- **Drop** any candidate that:
  - Has fewer than 2 modules AND no callbacks AND no GenServer.
  - Is entirely test code (someone's `test/support/`).
  - Is generated (`lib/mix/tasks/` from `mix new`, or anything with a
    `# This file is generated` header).
- **Merge** when two candidates share >50% surface. Prefer the higher-scored
  one's id; carry the rationale forward as "Merged with <other-id>".
- **Defer** anything the user is unsure about — uncovered files surface
  later as `branch_guard_unmapped_change` warnings, which is the natural
  prompt to carve another subject in a future PR.

## Presentation template

Print candidates to the user in groups of 10, sorted by score descending.
Use this exact format so the user can scan quickly:

```
Subject extraction — 12 candidates (showing 10 of 12)

[1] myapp.billing           (score 18, H1 Phoenix context)
    surface: lib/myapp/billing.ex, lib/myapp/billing/**/*.ex (7 files)
    tests:   test/myapp/billing/**/*_test.exs (4 files)

[2] myapp.storage_adapter   (score 14, H2 behaviour)
    surface: lib/myapp/storage/adapter.ex
    callbacks: 5 (put/3, get/2, delete/2, list/2, exists?/2)

[3] myapp.notifications     (score 11, H1 Phoenix context)
    surface: lib/myapp/notifications.ex, lib/myapp/notifications/**/*.ex (3 files)
    overlap: shares lib/myapp/notifications/mailer.ex with [7] myapp.mailer

...

Reply with: accept <n>, defer <n>, merge <n>+<m>, split <n>, all-accept, all-defer.
Anything not addressed defaults to defer.
```

The "anything not addressed defaults to defer" line matters — the user
should not feel obligated to triage every candidate before bootstrap can
move on. Deferred subjects come back as `branch_guard_unmapped_change` later.

## Drafting an accepted subject

For each accepted candidate, write `.spec/specs/<id>.spec.md`:

````markdown
# <Human-readable title>

<One-paragraph prose description derived from the modules' `@moduledoc`,
or "Bootstrap draft — refine in phase2." if no moduledoc exists.>

```yaml spec-meta
id: <candidate_id>
kind: module
status: draft
summary: <one-liner derived from moduledoc or candidate rationale>
surface:
  - lib/<...>
  - test/<...>
```

```yaml spec-requirements
- id: <candidate_id>.draft
  statement: Bootstrap draft — behavior to be specified in phase2 review.
  priority: should
  stability: evolving
# Only when a @doc or @moduledoc makes a real behavioral claim, add:
# - id: <candidate_id>.<function_or_callback>
#   statement: <one-line behavioral claim taken from the doc, not the function name>.
#   priority: should
#   stability: evolving
```
````

**Important constraints:**

- `status: draft` is mandatory. Promote to `active` only in phase2 when
  bindings are wired. Drafts skip strict requirement-coverage checks, so the
  placeholder requirements do not fail CI.
- `priority: should` (not `must`). Placeholder requirements should not gate
  on tag presence — a real review pass in phase2/3 elevates the priorities.
- The single "Bootstrap draft" placeholder is the default. Add per-function
  requirements ONLY where a `@doc` or `@moduledoc` makes a real behavioral
  claim you can restate — never derive a statement from a function name
  (see anti-patterns below). Phase2 review replaces the placeholder with
  real requirements or deletes the subject; no placeholder survives
  promotion to `status: active`.
- Do NOT write `spec-verification` yet. Verifications attach to real test
  files; phase4 wires them.
- Do NOT write `realized_by:` yet. That is phase2.

If `.spec/specs/<candidate_id>.spec.md` already exists, **skip the candidate
silently** and record it in the conflict list. Never overwrite an authored
spec.

## Anti-patterns

- **Don't make one subject per module.** Subjects should describe behavior,
  not file paths. A subject with `surface: [lib/myapp/foo.ex]` and one
  module is usually too small to be useful — the file-touch guard becomes
  redundant.
- **Don't make one subject for the whole app.** The whole point of subjects
  is that they bound the call-closure walk; if everything is one subject,
  every change is "behavior drift inside the subject".
- **Don't infer behavior from function names.** Function names are
  implementation, not contract. A starter requirement that says
  "`process_payment/2` shall process a payment" is worse than no
  requirement — it gives a false sense of coverage. Either pull the claim
  from a `@doc` string, or write the placeholder
  "Bootstrap draft — behavior to be specified in phase2 review."
- **Don't try to be complete.** Defer is fine. The bootstrap epic produces
  the on-ramp, not the finished product.

## Failure modes

- **No usable heuristic matches.** A non-Phoenix, non-OTP-shaped lib (a
  pure-function library, say) may produce zero candidates from H1–H3 and
  only H4 fallbacks. In that case, ask the user to nominate subjects
  directly; the heuristics are not a fit.
- **Massive candidate list (>50).** Probably an umbrella project or a repo
  with many small contexts. Take the top 20 by score and tell the user the
  rest will surface organically through `branch_guard_unmapped_change`.
- **All candidates score below 5.** The repo is too small or too uniform
  for the heuristics to discriminate. Recommend the user pick 1–3 subjects
  by hand based on what they actually care about.
