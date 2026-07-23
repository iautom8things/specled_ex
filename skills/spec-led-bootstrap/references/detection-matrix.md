# Detection matrix

This page is the canonical reference for Phase 1 of `/spec-led-bootstrap`. Every
classification the skill makes traces back to one of these signals.

## Dependency state

| Signal                                                       | Reading                          |
|--------------------------------------------------------------|----------------------------------|
| `grep spec_led_ex mix.exs` empty                             | Dep missing — must be added       |
| `grep spec_led_ex mix.exs` matches, but no `mix.lock` entry  | Locked-only — run `mix deps.get` |
| `mix deps | grep spec_led_ex` shows `not available` or path | Broken — re-fetch or fix path     |
| `mix deps | grep spec_led_ex` shows `(spec_led_ex X.Y.Z)`    | Installed                         |

`spec_led_ex` is the Hex name; agents that have been around longer may see it
under the package name `specled_ex` — accept either spelling when reading
`mix.exs`.

## Workspace tier

The five workspace tiers are defined by the **strongest** signal that fires.
Process top-down; the first match wins.

| Tier | Test (in order)                                                              |
|------|------------------------------------------------------------------------------|
| T0   | No `.spec/` directory exists                                                 |
| T1   | `.spec/` exists, but `.spec/specs/` is empty or contains only template stubs |
| T2   | At least one subject exists, but **all** subjects are `status: draft` and none has a `realized_by:` field |
| T3   | At least one subject is `status: active` with `realized_by:` OR at least one test carries `@tag spec:` |
| T4   | T3 AND the workspace has realization baselines or a `spec-evidence` ref AND a CI workflow references `mix spec.check` |

Template-stub detection (T1 vs T2): the files
`.spec/specs/spec_system.spec.md` and `.spec/specs/package.spec.md` come from
`mix spec.init`. If the only `.spec.md` files match those names AND their
SHA256 matches the upstream template (read from
`deps/spec_led_ex/priv/spec_init/specs/`), classify as T1, not T2.

### Pre-ledger legacy workspace (orthogonal to tier)

```bash
git ls-files .spec/state.json
```

Non-empty output means `.spec/state.json` is tracked — the workspace
predates the evidence-ledger split, and its tracked state file is a stale
snapshot, not current truth. Do not read a workspace tier or adoption phase
out of a tracked `state.json`. Classify as **pre-ledger** and emit one
migration ticket (running `mix spec.evidence.migrate`) alongside whatever
other tickets bootstrap produces. The "Pre-ledger migration" section of
[task-templates.md](task-templates.md) carries the ticket body and the
canonical list of what the migration does.

Every adopter that bootstrapped before the evidence-ledger split hits this
path; skipping the migration leaves drift detection comparing against a
frozen baseline.

## Runtime split — host vs container

```bash
ls docker-compose.yml compose.yml Dockerfile.dev 2>/dev/null
grep -E '\{:ecto' mix.exs
```

When a compose file or dev Dockerfile exists AND the app has a database
dependency, the repo likely runs its test suite inside a container while
Git lives on the host. This splits the verification loop:

- **Host side** — `mix spec.prime`, `mix spec.next`, `mix spec.check` are
  git-sensitive; they must run where the Git metadata is (the host).
- **Container side** — command verifications that need the app runtime
  (DB-backed tests, `mix test`) must run in the container.

Record `runtime: containerized` and ask the user for the two commands at
target-selection time: `<host_check_cmd>` (usually `mix spec.check
--no-run-commands`) and `<container_verify_cmd>` (e.g.
`docker compose exec app mix test`). Host-only repos collapse both to the
same `<verify_cmd>`. The phase0 ticket writes the split loop into the
scaffolded `.spec/AGENTS.md` so the friction is documented once, not
rediscovered per contributor.

## Conformance findings — interpretation

Run `mix spec.validate` and `mix spec.check --base HEAD~1` (or `--base HEAD`
on a fresh repo) and classify each finding.

### Schema-fatal (identifier validator + parse errors)

The verifier emits these finding codes when a spec parses but its
identifiers are wrong:

- `missing_requirement_id`
- `missing_scenario_id`
- `duplicate_requirement_id`
- `duplicate_scenario_id`

Parse-level breakage is **not** a finding code. When a `spec-*` fenced block
fails to decode — malformed YAML, wrong top-level shape (a mapping where a
list is required), or a schema-validation failure — `SpecLedEx.Parser` records
a `parse_errors` string on the spec (e.g. `"spec-meta decode failed: ..."`)
rather than emitting a code. A fenced block whose info-string is not one of the
recognized `spec-*` tags is silently ignored, so "unsupported block" is a
no-op, not a diagnostic.

These mean a spec file does not parse or carries broken ids. Bootstrap must
repair them before any new authoring — emit a **phase 0.5** ticket "Repair
malformed spec files" that lists each affected path. Do not attempt to repair
inline; the user authored those files and may have intent the skill cannot
recover.

### Corpus drift (validator/branch-guard)

- `append_only/requirement_deleted`, `append_only/must_downgraded`,
  `append_only/scenario_regression`
- `overlap/duplicate_covers`, `overlap/must_stem_collision`
- `branch_guard_realization_drift`, `branch_guard_dangling_binding`
- `branch_guard_unmapped_change`

The code strings above are the resolver defaults in `SpecLedEx.BranchCheck`
— use them exactly when classifying findings or writing severity overrides.
Unknown config keys do not error loudly; a misspelled code silently never
matches.

These mean the spec corpus is internally inconsistent or has drifted from
code. They are normal during a bootstrap on a stale repo. Group them by
finding code, count occurrences, and emit them as one ticket per code:
"Clear N `branch_guard_dangling_binding` findings" with the file list in
the deliverable.

### Detector unavailable

- `detector_unavailable :no_coverage_artifact`
- `detector_unavailable :umbrella_unsupported`
- `detector_unavailable :no_debug_info`

Not errors — these are tiers that opted in but cannot run. Surface them in
the detection summary so the user can decide whether to add coverage
capture (resolves `:no_coverage_artifact`) or accept the gap.

## Adoption-level signals

The **inferred current phase** is the highest N for which ALL phase-N
preconditions hold. Compute floor-zero.

| Phase | Precondition                                                              | Detection                                                                                       |
|-------|---------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------|
| 0     | dep installed and `.spec/` scaffolded                                     | dep state == installed AND workspace ≥ T1                                                       |
| 1     | at least one non-draft subject with non-empty `surface:`                  | parse `.spec/specs/*.spec.md`; count subjects with `status != draft` and `surface: [...]`        |
| 2     | at least one subject has `realized_by.api_boundary:` with ≥1 MFA          | parse `.spec/specs/*.spec.md`; count subjects with `realized_by.api_boundary` populated         |
| 3     | `test_tags.enabled: true` AND ≥1 `@tag spec:` in test files               | parse `.spec/config.yml`; grep `test/`                                                          |
| 4     | coverage artifact exists AND CI runs the capture step                     | check `.spec/_coverage/per_test.coverdata` exists; grep `.github/` for `mix spec\.cover\.(test|ingest)` |
| 5     | at least one subject has `realized_by.implementation:` with ≥1 MFA        | parse `.spec/specs/*.spec.md`                                                                   |
| 6     | `test_tags.enforcement: error` AND `branch_guard_realization_drift: error` | parse `.spec/config.yml`                                                                        |

Do not grep `test/test_helper.exs` for `SpecLedEx.Coverage.Formatter` as the
phase4 signal. Since epic `specled_-155`, the default `mix spec.cover.test`
needs no `test_helper.exs` wiring at all, and wiring the formatter in
directly is now an inert anti-pattern (one stderr notice, no artifact) —
its presence proves nothing about adoption level, and its absence is the
expected, correct state even at phase4. Detect from the artifact and CI
step instead.

Mixed-phase repos are common. Example: workspace T3 + adoption-level signals
say phase2 (because tags exist but coverage was never captured) means the
repo has skipped phase3/4 ordering. Treat the inferred phase as the floor
when picking `target_phase` — bootstrap fills in missing prior phases before
advancing.

## CI integration signal

Look for `mix spec.check` in any of:

```
.github/workflows/*.yml
.gitlab-ci.yml
.circleci/config.yml
buildkite/*.yml
```

The `.github/workflows/` path is by far the most common — treat absence
elsewhere as "no CI integration" unless the user states otherwise.

## Codebase shape — inputs for subject extraction

These signals only matter when subject extraction will run (current_phase < 1).

| Signal                              | Used for                                                       |
|-------------------------------------|----------------------------------------------------------------|
| `find lib -name '*.ex' | wc -l`    | Estimate work volume; >200 modules = recommend phase1 fan-out  |
| `find lib -maxdepth 2 -type d`      | Top-level cluster boundaries                                   |
| `grep -lE '^\s*use Phoenix\.Controller'` | Phoenix → context-based clustering                        |
| `grep -lE '^\s*use Ecto\.Schema'`   | Schemas often co-cluster with their context                    |
| `grep -lE '@behaviour'`             | Behaviour modules are strong subject anchors                   |
| `grep -lE 'use GenServer'`          | GenServers are often their own subject                         |
| `find test -name '*_test.exs' | wc -l` | Tag opportunities later (phase3)                            |

## Common false-negatives to watch for

- A repo can have `.spec/` directories from a previous, abandoned bootstrap.
  If `git log --all .spec/` shows commits but `.spec/specs/` is empty NOW,
  the prior attempt was rolled back. Classify as T0 but warn the user.
- A repo can have `@tag spec:` tags in test files that point at requirement
  ids that no longer exist. These count as "tagged tests" for phase3
  detection, but they cover nothing — no finding names the dangling tag
  itself, and any still-existing `must` requirements they were meant to
  cover keep firing `requirement_without_test_tag`. Surface a
  `dangling tag` count in the detection summary by diffing tag values
  against current requirement ids.

  Two related finding codes exist; do not use them interchangeably:
  - `requirement_without_test_tag` — validator-side (`mix spec.validate`
    and full checks). Fires for **every** `must` requirement covered by a
    `tagged_tests` verification that has no backing tag.
  - `branch_guard_requirement_without_test_tag` — branch-side
    (`mix spec.check --base ...`). Fires only for `must` requirements
    **newly added** relative to the base. This is the code
    `branch_guard.severities` configures.
- Umbrella projects degrade the `realized_by` tiers to
  `detector_unavailable :umbrella_unsupported`. Do not gate this on a
  version string — probe the capability instead: if `mix.exs` declares
  `apps_path:`, run `mix spec.check` once and look for
  `detector_unavailable` findings with reason `umbrella_unsupported`. If
  they appear, the installed SpecLedEx cannot walk realization tiers on
  this repo — classify as umbrella and recommend stopping at phase3. If a
  future release removes the limitation, the probe comes back clean and no
  advice changes are needed.
