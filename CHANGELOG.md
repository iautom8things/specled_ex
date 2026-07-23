# Changelog

## 0.4.0 — 2026-07-23

- `mix spec.check --accept-drift`: a durable acceptance path for INTENTIONAL
  realization drift. The accepting run refreshes the committed flat-tier baseline
  in a single pass and downgrades the drift to `:info`, so intentional drift does
  not resurface post-merge once the ephemeral `Spec-Drift:` trailer window closes.
  The silencing is scoped to exactly the tiers the refresh heals: implementation-
  tier drift stays at its configured severity (a signal, never accepted), and a
  dangling binding blocks the refresh entirely so no baseline moves on a failing
  run. (specled_-uv3)
- Extended `realized_by` attestation coverage so internals-only edits — e.g.
  editing a shared realization test that a subject binds via a `tagged_tests`
  verification — no longer hard-error the branch guard's subject co-change check
  for a subject whose contract did not change. (specled_-oyg)

## 0.3.4 — 2026-07-23

- `SpecLedEx.Realization.ApiBoundary.hash/2` is now position-invariant: editing
  lines above a bound function (for example an unrelated moduledoc change) no
  longer changes its api_boundary hash. The leak was `strip_meta/1` not
  recursing into a call node's callee (`form`), so a remote-call guard such as
  `is_map(x)` retained the `.` operator's line/column metadata; `strip_meta` now
  recurses into `form` as well. A regression test (proven to fail on the
  pre-fix code) guards the invariant, the `hash_function_head` requirement is
  tightened to name the previously-broken case, and the 45 committed
  api_boundary baselines whose functions carry a remote-call guard were
  rebaselined to their new invariant values. (specled_-o40)

## 0.3.3 — 2026-07-23

- The scaffolded `spec-review` GitHub Actions workflow
  (`priv/spec_init/workflows/spec_review.yml.eex`) now splits the untrusted-PR
  render from the write-scoped deploy. A read-only `render` job runs
  `mix spec.review` against the PR head and uploads the HTML as a workflow
  artifact; a separate write-scoped `deploy` job (`needs: render`) downloads
  the artifact, pushes gh-pages, and posts the PR comment while checking out
  only the trusted base branch (`ref: github.base_ref`). No single job both
  executes pull-request-provided code and holds a `contents: write` /
  `pull-requests: write` token, and top-level permissions default to
  read-only. New `must` requirement
  `specled.spec_review.gh_pages_privilege_separation` captures the invariant.
  (specled_-3q1)

## 0.3.2 — 2026-07-23

- Hardened two order/load-dependent test flakes surfaced by the
  full-suite/merged verification runs (specled_-f98). No product behavior
  changed — both fixes are test-only:
  - `test/specled_ex/verifier_test.exs` "a timeout with an empty artifact
    reports likely compile cost" now budgets `2000ms` (was `300ms`), matching
    its sibling timeout tests. The child must reach its first line to truncate
    the attribution artifact to empty; under full-suite load the three-level
    spawn lost that race against the 300ms process-group kill, leaving the
    artifact absent rather than empty and flipping the classified message off
    "likely compile cost".
  - `test/mix/tasks/spec_check_test.exs` is now hermetic with respect to the
    VM-global `SPECLED_SHOW_INFO`: a module `setup` deletes it for a clean
    per-test baseline and restores the prior value on exit (the old mutation
    test deleted rather than restored, and no baseline was asserted). An
    ambient or leaked `SPECLED_SHOW_INFO=1` no longer makes the unrelated
    ":info suppression" test fail seed-dependently.
  - The remaining logged observation (the `tracer_test.exs` `merge_edges`
    stream_data property one-off) was assessed as a sound property / likely
    timeout artifact under load, not a defect; carried to follow-up
    specled_-qvg for seed capture if it recurs.

## 0.3.1 — 2026-07-23

- Bare-module `api_boundary` entries no longer oscillate out of
  `.spec/realization_hashes.json`: the clean-run refresh recomputes their
  head-union hashes instead of skipping them, and the silent-seed pass and
  flat-tier refresh now share a single hasher
  (`Orchestrator.api_boundary_hashes/2`) so seed/refresh parity holds by
  construction. The shared hasher is pinned by a direct unit test (verified
  to fail if bare modules are skipped again) and a two-run stability test
  asserting the committed baseline stays byte-identical across consecutive
  clean runs. (specled_-rot)
- Post-review honesty pass on the co-change specs: reverted two
  guard-appeasing clauses padded onto `must` requirements
  (`specled.branch_guard.subject_cochange`,
  `specled.implementation_tier.closure_walks_tracer_edges`) and recorded the
  real current truth as Intent prose instead — the branch guard's dependence
  on stable realization baselines via the shared hasher, and the
  implementation tier's exclusion from the flat-tier refresh. Follow-up
  `specled_-oyg` tracks extending `realized_by` attestation coverage so
  internals-only changes stop demanding spec co-change ceremony.
  (specled_-rot)

## 0.3.0 — 2026-07-23

- The missing-ADR condition is now advised as a fork, not an ADR mandate.
  `mix spec.next`'s `needs_decision_update` guidance and the
  `branch_guard_missing_decision_update` finding state the durable-policy
  rubric first (does the change constrain future changes, span subjects
  beyond this branch, or record a rejected alternative?) and then both
  resolution arms — add or revise an ADR (`mix spec.decision.new`), or
  record `Spec-Drift: branch_guard_missing_decision_update=info` as a git
  trailer with a one-line reason in the commit body. The finding message
  now ends with a code-fenced `fix:` block matching the `append_only/*`
  convention. The same fork appears everywhere the ADR obligation is
  described: the `mix spec.prime` loop lines (default and `--bugfix`),
  both decisions READMEs (workspace and `spec.init` scaffold), and the
  scaffold README + local skill, which also gains a triage-table row for
  the finding. ADR `specled.decision.decision_fork_advertised_at_decision_points`
  records the policy — per-range, history-auditable trailers over silent
  repo-wide config demotion. Existing trailer semantics are unchanged:
  range-wide, `trailer > config > default`, config `:off` absorbing.
  (specled_-4kg)
- Post-review hardening from the six-agent critical review: the prime loop
  advertisement is pinned by a new `must` requirement
  (`specled.prime.decision_fork_loop_line`) with a tagged test covering
  both loop variants, and the previously unmapped scaffold
  `decisions/README.md.eex` is now claimed by `specled.package`'s surface
  so future edits to it face the co-change guard. (specled_-4kg)

## 0.2.0 — 2026-07-22

- Fixed unbounded pre-push hook recursion on the first real evidence sync:
  the installed pre-push hook runs `mix spec.sync`, whose ledger push
  re-triggered the hook, which ran sync again — spawning nested pushes
  forever and minting an endless chain of identical ledger commits. Ledger
  pushes now run with `--no-verify`; the developer's own code pushes still
  see their hooks, and the hook still runs sync exactly once per push.
- Unified tree-blob reading on one primitive and deduplicated helpers.
  `BaseView` now materializes base spec files through `Git.ls_tree_entries/3`
  plus one `Git.cat_file_batch/3` call — the same batched plumbing `Sync`
  uses — instead of one `git show` spawn per file on the `spec.check --base`
  path. New `SpecLedEx.TaskArgs.validate!/3` and
  `SpecLedEx.Evidence.Warnings.emit/1` replace the per-task copies of arg
  validation and warning printing in the evidence-family mix tasks, and the
  triplicated git-plumbing test helpers (`inject_raw_entry`, `evidence_ids`,
  `drop_non_evidence_refs`, `lock_down`/`unlock`) now live once in
  `SpecLedEx.EvidenceHelpers` under `test/test_support/`.
- Extended evidence-ledger hardening after a second review round. The prune
  reachability floor now guards the outcome rather than only the computation:
  a keep-set that would filter a non-empty store down to nothing — empty or
  merely disjoint from every stored evidence key — makes `mix spec.prune`
  refuse and auto-prune degrade to an unpruned merge with a warning. Sync
  tolerance now extends to the tree layer: crafted non-blob entries
  (gitlinks) are carried through byte-identical at the tree level with a
  quarantine warning, and entries at paths git refuses to stage (`..`,
  `.git`) are dropped from the union with an `evidence/entry_skipped`
  warning so the store self-heals instead of wedging every peer's
  reconcile. The batched-I/O contract is now falsifiable: a new
  `specled.evidence_store.sync_bounded_subprocesses` requirement is backed
  by a spawn-counting test and a 205-entry chunk-boundary reconcile test,
  plus `cat_file_batch` protocol-edge tests (newline-bearing,
  header-lookalike, empty, and >64KB multi-read blobs).
- Hardened the evidence ledger following critical review. `Sync` now reads a
  ref's entries through one `ls-tree -r -z` plus one `git cat-file --batch`
  subprocess and writes merged trees through chunked `hash-object` /
  `update-index --cacheinfo` invocations — a bounded number of git spawns per
  reconcile instead of roughly four per entry on the pre-push hot path. An
  empty reachable keep-set is now a reachability-floor violation rather than a
  valid prune: `mix spec.prune` refuses with `evidence/prune_refused` (a
  detached or ref-less CI checkout can no longer wipe every peer's evidence)
  and sync's auto-prune degrades to an unpruned merge with one
  `evidence/auto_prune_degraded` warning. See the new
  `specled.evidence_store.prune_reachability_floor` requirement. Also fixed
  `Store.build_tree/3` leaking its temporary index file on error paths, and
  added test coverage for the migrate task's legacy-realization hoist.
- Updated docs, shipped bootstrap references, and `mix spec.init` templates for
  the evidence-ledger flow: `.spec/state.json` is described as derived local
  state, committed baselines live in `.spec/realization_hashes.json`, and CI
  examples fetch `spec-evidence` read-only with the unauthenticated-attestation
  caveat.
- Fixed `SpecLedEx.Compiler.Tracer` truncating the callee-graph side-manifest on incremental compiles: flush now merges — the pre-session manifest (read once per compile session, seed-time pruned of callers absent from a non-empty compile manifest) minus entries whose caller module was compiled this session (tracked from `:on_module`, so a recompiled module with zero remote calls still drops its stale entries), unioned with the session's edges, callee lists sorted and deduplicated, written atomically via unique temp file + rename. The effective edge graph after an incremental compile now equals a forced full compile; consumers can drop `mix compile --force` workarounds from spec-check jobs. Trace-time tracer code is now self-contained (Mix/stdlib calls only) because Mix's compile-time code-path pruning strands lazily-loaded sibling modules for projects loading the tracer via `ERL_LIBS`. See `specled.decision.tracer_manifest_merge_on_flush`.
- Added read-time ghost filtering in the implementation tier: when the compile `Context` carries a non-empty manifest, tracer edges whose caller module is outside the in-project set are dropped at world build (the authoritative prune; the tracer's seed-time prune only bounds file growth). A nil or empty manifest disables the filter. New `specled.implementation_tier.deterministic_hashes` contract: two consecutive runs over an unchanged tree produce identical hashes and findings.
- **Breaking for committed implementation-tier baselines:** `mix spec.check` now constructs a compile `Context` via the new `Context.from_mix_project/1` whenever its root is the current working directory, so realization tiers receive the real compile manifest. Implementation-tier closures now walk the full in-project module set (surface-based ownership and shared-helper inlining are active in production for the first time), which changes committed implementation hashes. Consumers must re-seed once: delete the `implementation` section of `.spec/realization_hashes.json` and run `mix spec.check` on a clean tree (Atlas: re-enable the tier in `.spec/config.yml` first). `api_boundary` baselines are unaffected. Also fixed `Context.load/1`'s default manifest path, which resolved under `ebin/` and silently loaded zero modules; the default is now the app dir's sibling `.mix/compile.elixir`, and the integration canary asserts a non-empty manifest through the default derivation.

- Split the committed realization-hash baseline out of `.spec/state.json` into a dedicated `.spec/realization_hashes.json` (canonical sorted output, atomic tmp+fsync+rename writes). `state.json` is now freely regenerable derived state — consumers may gitignore or regenerate it without defeating drift detection. Migration is one-shot and automatic: `HashStore.read/2` falls back to a legacy embedded `realization` section while the dedicated file is absent, `HashStore.merge/2` migrates legacy entries forward, and `SpecLedEx.write_state/4` hoists an embedded section into the dedicated file before regenerating state.json. This also fixes a latent bug where `mix spec.check` wiped the embedded baseline (via `write_state`) before the branch guard read it, so in-pipeline realization drift detection never fired. Both tool-managed files are excluded from branch-guard change sets. See `specled.decision.dedicated_realization_baseline`.

- Migrated every `kind: command` `mix test <files>` verification in `.spec/specs/*.spec.md` to `kind: tagged_tests`, so the verifier issues a single merged `mix test --only spec:<id>... --include integration <files>` invocation instead of 53 separate BEAM boots. Test modules referenced by the old commands now carry `@moduletag spec: [...]` aggregating the covers list per file; `@tag spec: ...` annotations on individual tests compose additively. Enabled `test_tags` in `.spec/config.yml` (`enabled: true`, `paths: [test]`, `enforcement: warning`). `SpecLedEx.TaggedTests.build_command/2` appends `--include integration` as a defensive no-op for host projects that configure `ExUnit.configure(exclude: :integration)`. Helper migration scripts live under `priv/helper_scripts/` and are part of the `specled.tagged_tests` subject's surface. The non-`mix test` commands (`mix spec.index`, `mix spec.validate`, `mix run -e ...`) remain as `kind: command` because aggregation does not apply.
- Extended `SpecLedEx.TagScanner` to recurse into `describe/2` blocks so `@moduletag spec:` attaches to tests nested under `describe`, and `@tag spec:` declared inside a `describe` block attaches to the following nested test. Pre-existing scans of top-level tests are unchanged. New `specled.tag_scanning.describe_block_recursion` requirement covers the behaviour.
- Narrowed `specled.verify.requirement_without_test_tag` (and its branch-guard sibling `branch_guard_requirement_without_test_tag`) to fire only for `must` requirements that are covered by at least one `tagged_tests` verification on their owning subject. Requirements covered exclusively by `source_file`, `command`, or other file-based kinds no longer produce this finding, because those verifications do not rely on `@tag spec:` annotations for coverage signal.
- Extended `SpecLedEx.Coverage.subject_file_map/2` to resolve `kind: tagged_tests` verifications into their backing test files via the index's `test_tags` map, so the branch guard's `branch_guard_unmapped_change` check recognizes test files reached through tag annotations instead of target globs.
- Added `guardrails.severities` in `.spec/config.yml` as a separate severity-override namespace for the 12 `append_only/*` + `overlap/*` finding codes, parsed into `SpecLedEx.Config.Guardrails` and routed through `SpecLedEx.BranchCheck.Severity.resolve/3` as a second config layer that is disjoint from `branch_guard.severities`. Unknown severity tokens are dropped with a `config_warning` diagnostic, matching `branch_guard.severities` exactly.
- Added a `--verbose` flag on `mix spec.check` that, together with `SPECLED_SHOW_INFO=1`, un-filters `:info`-severity findings from stdout. Default `mix spec.check` output now suppresses `:info` findings from the printed stream; `.spec/state.json` still carries every finding unchanged.
- Added `SpecLedEx.Overlap`, a pure head-only detector that emits `overlap/duplicate_covers` at `:error` when two scenarios in the same subject both list the same requirement id in their `covers:` field, and `overlap/must_stem_collision` at `:error` when two `must`-priority requirements in the same subject share the same canonicalized MUST stem. Both checks are strictly within-subject; cross-subject collisions are ignored.
- Wired `SpecLedEx.AppendOnly.analyze/4` and `SpecLedEx.Overlap.analyze/2` into `SpecLedEx.BranchCheck.run/3`. All 12 new codes (10 `append_only/*` + 2 `overlap/*`, per `specled.decision.append_only_finding_budget`) are routed through `BranchCheck.Severity.resolve/3`, so `Spec-Drift:` trailers and `branch_guard.severities` config overrides apply uniformly. AppendOnly emission short-circuits when `--base` is `HEAD` or the working tree is not a git repo — those are trivial comparisons with no prior state to diff against. `--base` is now validated as a commit via `git rev-parse --verify "<base>^{commit}"` so non-commit refs raise a clean `ArgumentError`. The shallow-clone preflight uses `System.cmd/3` with `into: ""` (no `stderr_to_stdout`).
- Added `SpecLedEx.AppendOnly`, a pure diff-time validator that compares a prior `state.json` against the current state plus a head-side decisions list and emits findings for requirement deletion, modal downgrade, scenario regression, polarity loss, disabled-without-reason, absent baseline, accepted-ADR structural drift, same-PR self-authorization, missing `change_type`, and ADR deletion. Authorization defers to the 4-value weakening set (`deprecates`, `weakens`, `narrows-scope`, `adds-exception`); every finding message ends with a code-fenced `fix:` block. `SpecLedEx.normalize_for_state/1` is now a public pure function so callers and tests can consume the canonical state shape without writing to disk; `normalize_decisions` now carries `change_type`, `reverses_what`, and `replaces`.
- Added per-test coverage capture: `mix spec.cover.test` wraps `mix test --cover` with a serialized run (forces `async: false` and warns about test files that opt back in), and `SpecLedEx.Coverage.Formatter` writes per-test snapshots through anonymous ETS to `.spec/_coverage/per_test.coverdata`. `SpecLedEx.Coverage.Store` reads/writes the artifact and exposes a `build_records/1` helper. `mix test --cover` continues to work unchanged in cumulative mode.
- Added `SpecLedEx.BranchCheck.Severity`, a single resolver for per-finding severity with the precedence `trailer_override > config.severities > per_code_default`. `:off` in config is absorbing — it beats any trailer override — and unknown values fall back to the per-code default with a `Logger.warning/1`.
- Added `SpecLedEx.BranchCheck.Trailer`, which parses `Spec-Drift:` git trailers (`refactor`, `docs_only`, `test_only`, or explicit `<code>=<severity>`) and shells `git log <base>..HEAD` so trailers written on any commit in the PR range apply to the whole range. HEAD-only scanning is deliberately not supported.
- Added `SpecLedEx.PolicyFiles`, a single place to ask whether a changed path is `:lib`, `:test`, `:doc`, `:generated`, or `:unknown` and which co-change rule applies. `priv/` defaults to `:lib`; only `priv/plts/` is `:generated`, preserving migration and static-asset signal. `docs/plans/` is `:doc` but always `:ignored` for co-change. `SpecLedEx.ChangeAnalysis` now delegates to it.
- Added `SpecLedEx.Config.BranchGuard` and `SpecLedEx.Config.Prose`, zoi-backed config sections. `branch_guard.severities` configures severity overrides by finding code; `prose.min_chars` (default 40) and `prose.min_words` (default 6) configure the prose-rot threshold. Negative and non-integer values are rejected with a diagnostic.
- Added a `spec_requirement_too_short` finding from `mix spec.validate` for any `must` requirement whose statement falls below the char or word threshold. The finding routes through `Severity.resolve/3` with a per-code default of `:info`; setting the code to `:off` in `branch_guard.severities` suppresses it. Non-`must` requirements are exempt.
- Added a `tagged_tests` verification kind that targets tests by their `@tag spec:` annotations instead of a file path. Executable `tagged_tests` entries across all subjects are aggregated into a single `mix test --only spec:<id>... <test_files>` invocation per spec-check run, replacing the N cold-starts that per-subject `kind: command` verifications incurred. Strength progresses `claimed → linked → executed` the same as other kinds; a new `tagged_tests_cover_missing_tag` warning fires (when tag scanning is on) for covers that no test actually carries. New module `SpecLedEx.TaggedTests` owns entry collection and command assembly; new subject `specled.tagged_tests` documents the contract.
- Added opt-in test-tag scanning that links requirements to the tests that cover them. `SpecLedEx.TagScanner` walks configured test directories via `Code.string_to_quoted/2` (no compilation) and extracts ids from `@tag spec: "<id>"`, `@tag [spec: ..., ...]`, `@tag spec: ["a", "b"]`, and `@moduletag spec` annotations. Scanner output flows through the index and powers four new verifier findings (`requirement_without_test_tag`, `verification_cover_untagged`, `tag_scan_parse_error`, `tag_dynamic_value_skipped`) and one new branch-guard finding (`branch_guard_requirement_without_test_tag`) for new `must` requirements added on the current branch.
- Added `SpecLedEx.Config`, a workspace-scoped config loader for `.spec/config.yml` with keys `test_tags.enabled` (boolean), `test_tags.paths` (list of strings), and `test_tags.enforcement` (`warning` | `error`). Missing or malformed config degrades to defaults; unknown enforcement values log a warning. `mix spec.init` now scaffolds `.spec/config.yml` alongside the rest of the workspace.
- Added `--test-tags` / `--no-test-tags` flags on `mix spec.check` and `mix spec.validate` to override the workspace config for a single invocation. Precedence is CLI flag > `.spec/config.yml` > built-in default.
- Added durable ADR support under `.spec/decisions/*.md`, including `mix spec.adr.new`, decision indexing in `.spec/state.json`, subject-to-ADR references through `spec-meta.decisions`, and verifier checks for ADR structure, affects, and supersession links.
- Added `mix spec.report` and `mix spec.diffcheck` so repositories can summarize current coverage and enforce diff-aware co-changes without introducing persistent in-flight `.spec` artifacts.
- Changed `mix spec.init` to scaffold `.spec/decisions/README.md` and refreshed the generated local Skill guidance around ADRs, current-truth subject updates, `mix spec.report`, and `mix spec.diffcheck`.
- Added an interactive `mix spec.init` prompt that can scaffold a local Skill for Spec Led Development alongside the `.spec/` starter workspace.
- Changed `mix spec.init` to scaffold both `.spec/README.md` and `.spec/AGENTS.md`, keeping human-facing workspace docs and agent-facing operating guidance separate.
- Tightened the package's self-hosted specs to prefer targeted command verifications for behavior-heavy subjects, so `mix spec.check` passes cleanly under strict file-reference linking.
- Promoted `verification_target_missing_reference` from `info` to `warning`, so strict verification now fails when file-backed verification targets do not mention the ids they claim to cover.
- Changed `mix spec.check` to execute eligible `kind: command` verifications by default while keeping `mix spec.verify` command execution opt-in.
- Added verification strength reporting with `claimed`, `linked`, and `executed` levels plus `--min-strength` / `spec-meta.verification_minimum_strength` thresholds.
- Made `.spec/state.json` canonical and diff-friendly by removing volatile persisted fields, sorting output deterministically, and skipping no-op rewrites.
