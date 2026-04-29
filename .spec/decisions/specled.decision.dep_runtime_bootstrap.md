---
id: specled.decision.dep_runtime_bootstrap
status: accepted
date: 2026-04-28
affects:
  - specled.mix_tasks
change_type: clarifies
---

# Spec Tasks Shall Bootstrap Their Own Dep Runtime

## Context

`specled.decision.no_app_start` removed `Mix.Task.run("app.start")` from every
`mix spec.*` task so that spec tooling does not couple to the host OTP
application's boot. That decision left an implicit assumption: the BEAM
applications that specled itself depends on at runtime — `:yaml_elixir` and
`:jason` — would be started by some other path before a spec task touched them.

When specled is consumed as a Hex dependency rather than run from this repo,
that assumption breaks. Modules like `SpecLedEx.Config`, `SpecLedEx.Index`,
`SpecLedEx.BranchCheck`, `SpecLedEx.DecisionParser`, `SpecLedEx.Parser`,
`SpecLedEx.Realization.HashStore`, and `SpecLedEx.JSON` call into
`YamlElixir`/`Jason` before either app has been started, and the task crashes
with an undefined-application error. Almost every `mix spec.*` task reaches
one of those modules transitively, so the failure is universal in dep mode.

## Decision

Each `mix spec.*` task shall, before doing any work in `run/1`:

1. Declare `@requirements ["app.config"]` so the host project's compiled
   config is loaded (without starting the host app).
2. Call `SpecLedEx.MixRuntime.ensure_started!/0`, which calls
   `Application.ensure_all_started/1` for every BEAM application specled needs
   at runtime (currently `:yaml_elixir` and `:jason`).

`mix spec.cover.test` is the single deliberate exception: it omits
`@requirements ["app.config"]` because it is invoked inside child-BEAM test
fixtures that load the parent `spec_led_ex` ebin via `SPECLED_EX_EBIN` /
`Code.append_path`. Mix's `app.config` rewrites the code path to only the
fixture's declared deps, evicting the parent ebin before `run/1` can lazily
load `SpecLedEx.MixRuntime`. The helper call itself is still required.

The helper lives in the dep itself (`lib/specled_ex/mix_runtime.ex`) so the
list of required apps stays in one place; new task modules opt in with a
single call.

This is a deliberate refinement of `specled.decision.no_app_start`, not a
reversal: spec tasks still must not start the *host* OTP application. They
start only the dep apps that specled's own modules need.

## Consequences

- Spec tasks work identically whether specled is the current project or a Hex
  dependency. Dep-mode crashes from missing `:yaml_elixir`/`:jason` are gone.
- Spec tasks remain decoupled from host application boot — the host's
  supervision tree is never started by a spec task.
- New `mix spec.*` tasks must follow the pattern. The `specled.tasks.dep_runtime_bootstrap`
  requirement on `specled.mix_tasks` carries a structural verification that
  greps every task source file for the helper call, so a missing call surfaces
  as a finding rather than a runtime crash in a downstream project.
- If specled later depends on additional BEAM applications at runtime, the
  fix is one line in `SpecLedEx.MixRuntime` rather than an edit per task.
