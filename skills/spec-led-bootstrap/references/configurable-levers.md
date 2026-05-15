# Configurable levers — `.spec/config.yml`

Every setting in `.spec/config.yml` that bootstrap touches, what flipping
it does, and when the skill should flip it.

## test_tags

```yaml
test_tags:
  enabled: false           # ← phase3 flips to true
  paths:
    - test
  enforcement: warning     # ← phase6 flips to error
```

- `enabled: true` — turns on the `@tag spec:` scanner. Required for phase3+.
- `paths:` — directories the scanner walks. Default `test`. Multi-app repos
  may need additional entries (e.g. `apps/myapp/test`).
- `enforcement:` — `warning` lets `mix spec.check` exit 0 with findings;
  `error` fails the gate. Bootstrap leaves at `warning` through phase5;
  phase6 raises to `error`.

## guardrails.severities

Append-only and overlap detectors. Default severity per code lives in
SpecLedEx.Config; override here only when bootstrap is graduating.

```yaml
guardrails:
  severities:
    append_only/requirement_deleted: error      # ← phase6
    append_only/modal_downgraded: error         # ← phase6
    append_only/scenario_regression: error      # ← phase6
    overlap/duplicate_covers: error             # ← phase6
    overlap/requirement_overlap: warning        # leave at warning during bootstrap
```

`overlap/requirement_overlap` is intentionally noisy on partially-authored
specs (e.g. during phase2 review). Keep at `warning` indefinitely unless
the team specifically wants overlap to gate.

## branch_guard.severities

The triangle-side detectors. These come online in phases 2, 3, 4, 5 — each
phase's gate behavior is driven by which codes are at `warning` vs `error`
vs `:off`.

```yaml
branch_guard:
  severities:
    branch_guard_realization_drift: warning           # phase2 default; phase6 raises to error
    branch_guard_dangling_binding: warning            # phase2 default; phase6 raises to error
    branch_guard_untested_realization: warning        # phase4 brings online; usually stays at warning
    branch_guard_untethered_test: warning             # phase4 brings online
    branch_guard_underspecified_realization: warning  # phase4 brings online
    branch_guard_requirement_without_test_tag: warning # phase3 brings online
    branch_guard_unmapped_change: info                # phase1 brings online; usually :info, not warning
```

### Opt-out patterns

When the user skips a tier permanently, bootstrap writes `:off` for the
relevant codes so they do not nag forever:

```yaml
# Coverage triangulation skipped permanently
branch_guard:
  severities:
    branch_guard_untested_realization: :off
    branch_guard_untethered_test: :off
    branch_guard_underspecified_realization: :off

# Umbrella project — these will degrade automatically but :off
# is more explicit
branch_guard:
  severities:
    branch_guard_realization_drift: :off
    branch_guard_dangling_binding: :off
```

## Severity ladder

`:off` → `:info` → `:warning` → `:error`

- `:off` — does not run; not in `state.json`.
- `:info` — runs and stores in `state.json` but hidden from default output.
  Show with `--verbose` or `SPECLED_SHOW_INFO=1`.
- `:warning` — visible by default; does not fail the gate.
- `:error` — fails `mix spec.check` (non-zero exit).

Bootstrap should never write `:info` for the high-trust codes
(`branch_guard_realization_drift`, `branch_guard_dangling_binding`). Either
the team trusts the code (`:warning` or `:error`) or they do not
(`:off`) — `:info` is a debugging mode, not an adoption stance.

## Per-PR escape hatches (no config change required)

These belong in commit trailers, not `config.yml`. Bootstrap should mention
them in `.spec/AGENTS.md` so future contributors know they exist:

```
Spec-Drift: <code>=<severity>
Spec-Drift: refactor
Spec-Drift: docs_only
Spec-Drift: test_only
```

Trailer downgrades apply to one PR (all commits in the range). They can
demote `:error` → `:warning`/`:info` but cannot revive `:off`. The shorthand
trailers (`refactor`, `docs_only`, `test_only`) downgrade common classes
of low-risk codes — read SpecLedEx.Config for the exact mapping.

## Local-only escape

```bash
mix spec.check --no-run-commands     # skip command verifications in local loop
mix spec.check --verbose             # surface :info findings
SPECLED_SHOW_INFO=1 mix spec.check   # same, env var form
```

Bootstrap should note in `.spec/AGENTS.md`:

> CI always runs the full gate. `--no-run-commands` is for the fast local
> loop only.

## Subject-level escape

`status: draft` on a subject skips strict requirement checks. Bootstrap
phase1 writes every extracted subject as `draft`; phase2 promotes to
`active`. Do not ship `draft` subjects to main long-term — the bootstrap
epic's phase2 ticket is what graduates them.

## What bootstrap should never write

- Workspace-wide `:off` on `parser/*` codes — parser errors mean specs
  do not parse; suppressing them silently breaks downstream tools.
- `enforcement: error` on `test_tags` before phase6 — premature lockdown.
- `branch_guard_realization_drift: error` before phase2 has a baseline —
  the first run after wiring bindings will fire on every subject because
  no hashes exist yet to compare against.
- Severities for tiers the project explicitly opted out of — write `:off`
  instead, so the absence is visible in `state.json`.
