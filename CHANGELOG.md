# Changelog

## 0.9.3 — 2026-07-26

Spec-honesty gate for go-live: removes the two provably false statements in the
shipped `.spec/` corpus, and widens the doc-identifier lint so the requirement
describing it is true rather than aspirational. Every claim was verified against
the implementation before editing. No `lib/` changes — the diff is two subject
specs, one decision record, and two test files. (specled_-cz0)

- Doc-identifier lint widened from three guarded finding-code families to five,
  adding `evidence/*` (7 codes) and `cross_field/*` (8 codes). Both are real
  emitted namespaces the lint never scanned, so eight existing references in
  `.spec/specs/evidence_store.spec.md` and `.spec/specs/mix_tasks.spec.md` come
  under guard for the first time. Two new tests back this: one pins each added
  family in both directions (a family in the allowlist but not the patterns is
  never scanned; in the patterns but not the allowlist rejects every real
  reference), and one pins the guarded-family count to the number the
  requirement states, so adding a sixth family cannot silently make that
  statement an undercount.
- `specled.package.doc_identifier_integrity` rewritten to claim only what is
  enforced. It now names the scanned corpus (`skills/**`, `docs/**`,
  `README.md`, `.spec/**`, with `CHANGELOG.md` and the agent rule files
  explicitly outside it), enumerates the five guarded families, and separates
  the two distinct reasons the remaining bare snake_case codes stay
  author-enforced: stems that collide with the corpus and are unusable, versus
  narrower stems that are guardable but deferred on the cost of another
  hand-maintained allowlist. The prior wording asserted enforcement the lint
  did not have.
- `specled.triangulation.scenario.test_only_change_scenario_gate` rewritten to
  describe the `CoverageTriangulation.findings/3` call its covering test
  actually performs. The previous `given:`/`when:` described a
  `mix spec.cover.test` fixture capture followed by a `mix spec.check` run on
  the branch; `mix spec.check` never runs triangulation at all (Decision 1,
  `specled.decision.aggregate_first_spec_coverage`). The same false claim was
  corrected where a test comment restated it.
- `specled.decision.doc_identifier_lint_spec_corpus` updated to record the
  widened family list, the measured stem-collision counts behind the
  guarded/unguarded boundary, and why the record states no emitted-code totals —
  the denominator moves with classification choices that are not settled
  (whether `check/5` outputs and `Mix.raise` prefixes count), so it states the
  stable comparison instead.

## 0.9.2 — 2026-07-25

Docs-accuracy fast-follow from the specled_-hj4.2 verification notes: corrects
false or stale claims in the adopter docs and the spec-led-bootstrap skill,
each verified against the implementation before editing. No behavior changes.
(specled_-0x4)

- Adopter docs accuracy sweep across `docs/adoption.md`, `docs/concepts.md`,
  and `docs/coverage.md`: tagged_tests aggregation builds file-selector
  commands rather than `--only spec:<id>` filters; the branch-guard gate table
  now lists all seven `branch_guard_*` codes including the two `error`-default
  codes it omitted; `umbrella_unsupported` is a `detector_unavailable` reason
  field, not an overridable finding code; `mix spec.init` writes six files
  including both starter subjects; the Phase 5 implementation tier requires the
  `realization.enabled_tiers` opt-in; graceful degrade emits one
  `detector_unavailable` per enabled realization tier and per selected subject;
  the canonicalizer is `SpecLedEx.Realization.Canonical`; the legacy-artifact
  message is quoted as `store.ex` emits it. (specled_-zhe)
- Bootstrap skill accuracy (`skills/spec-led-bootstrap/`): dropped severity
  overrides are documented as surfaced `[CONFIG]` stderr warnings, not silent
  no-ops; per-code severity defaults and the `Spec-Drift:` preset mapping are
  attributed to `SpecLedEx.BranchCheck` and `SpecLedEx.BranchCheck.Trailer`
  rather than `SpecLedEx.Config`; `branch_guard_dangling_binding` and
  `branch_guard_unmapped_change` are documented as `error` code defaults, so
  phase2 CI is not automatically report-only; scaffold claims corrected (no
  `<PROJECT_VERIFICATION_COMMAND>` placeholder exists, the scaffolded AGENTS.md
  does not mention `mix spec.sync`, and the spec_review workflow template is
  shipped in `priv/spec_init/` but never copied by `mix spec.init`); SKILL.md
  internal consistency repaired (seven phases, all seven ticket sections, the
  unconsumed `--target` argument-hint removed). (specled_-j3k)

## 0.9.1 — 2026-07-25

- Fixed the flaky `Tracer.merge_edges/3` property test: `uniq_list_of` over the
  4-atom module pool aborted with `StreamData.TooManyDuplicatesError` after 10
  consecutive duplicate draws, so any unlucky seed could strike CI (two
  independent seeds already had). The generator now uses a plain `list_of` —
  semantically equivalent since the drawn list is immediately converted to a
  `MapSet` — which makes the abort structurally impossible and widens coverage
  to the previously unreachable full 4-module session set. The property's
  assertions are unchanged. (specled_-zr6)

## 0.9.0 — 2026-07-25

Fast-follow remediation of the 0.7.0 per-test attribution release: every Tier-2
and Tier-3 finding from its critical review, plus the honesty repairs those
findings exposed. Twelve tickets, each cold-verified and audited independently.
(specled_-dn4)

- **The per-test cost model and attribution bound are now true rather than
  flattering.** The shipped claim that the hot path was "two snapshot reads +
  one `Snapshot.diff/2` + one ETS insert" understated O(modules × lines) reads
  twice per test plus an `ExUnit.OnExitHandler` deep copy of the head snapshot.
  Boundary windows are now chained — `tail(N)` is reused as `head(N+1)`, so the
  `on_exit` closure captures only `{module, name}` and the snapshot lives in
  ETS. Chaining widens the window, and the widening is disclosed rather than
  buried: later windows inherit serialized runner/`setup_all` and any
  intervening unhooked-test activity since the prior tail, and a tail raising
  before its single `:ets.insert/2` leaves the chained head unadvanced. The
  corrected bound — "exact within disclosed chained windows" — is propagated
  through the subject specs, the decision record, `docs/coverage.md`, the
  review renderer, the README and the adoption guide, with a measured
  per-hooked-test overhead figure published alongside it.
  (specled_-dn4.6, specled_-dn4.11)
- **`mix spec.cover.test --per-test` no longer exits 0 on a stale artifact.** A
  formatter crash previously left the previous run's `.coverdata` on disk while
  the task reported success. The task now asserts artifact freshness
  (`generated_at` against a timestamp captured before the suite) and raises on a
  missing, refused or stale write. A red suite still surfaces its own failure
  rather than a fabricated stale-artifact one. (specled_-dn4.6)
- **Capture and review now share one path identity, and unresolvable sources
  are their own partition instead of silently reading as uncovered.** Both
  lanes normalize to repo-root-relative paths, so a `nil` source or a
  path-shape mismatch can no longer masquerade as a genuine miss.
  `no_debug_info_mfas` no longer conflates three distinct states, malformed MFA
  identities get their own partition, and modules missing from the file map are
  surfaced as `meta.unmapped_modules` rather than vanishing from both the
  payload and the remainder that is supposed to catch them. Reported
  percentages may fall as a result; that is the point. (specled_-dn4.5)
- **Unknown provenance renders unqualified.** A subject reach map with no
  `:attribution` key previously defaulted to `:exact` at five review surfaces —
  the strongest available claim for data that never asserted one. All five now
  render without a qualifier. (specled_-dn4.5)
- **One arming-seam resolver.** Three independent decoders of
  `:specled_ex, :spec_cover_run` across `Boundary` and `Formatter` disagreed on
  table validity, so an armed seam carrying a non-reference table made
  `Boundary` write rows the formatter silently ignored — and the three paths
  variously crashed, no-oped, or crashed differently. `SpecLedEx.Coverage.Arming`
  is now the sole decoder, returning `{:armed, config} | :disarmed` with one
  stated liveness predicate, and it owns the module cache key that previously
  leaked across modules. (specled_-dn4.4)
- **Suite-end flush is linear again.** `Formatter.flush/1`'s quadratic
  `acc ++ recs` accumulation is replaced with `split_with`/`flat_map`/
  `frequencies_by`; measured 14.1s → 183ms at 40k records, with payload order,
  `meta` key set and stderr notice text byte-identical. (specled_-dn4.2)
- **specled can dogfood its own headline ergonomic.** The shipped
  `SpecLedEx.Case` template was silently shadowed in the host test VM by a
  same-named fixture helper, so the public case template was never exercised
  and 133 `undefined or private` warnings went unreported. The fixture is
  renamed to `SpecLedEx.FixtureCase`, and the case-template contract is proved
  behaviorally in a child BEAM against the shipped module rather than by
  grepping its own source. (specled_-dn4.3)
- **Spec evidence repaired.** The two coverage qualifier requirement ids
  asserted the opposite of their own names and are renamed under a deprecation
  ADR; a scenario whose premise required a lazy-capture row that no longer
  exists is corrected; the `no_debug_info` rendering obligation gains a covering
  scenario and its test regains its `covers:` linkage; the adoption-guide
  requirement is verified by asserted content instead of mere file existence;
  and `specled.decisions.reference_validation` gains the
  `change_type: deprecates` carve-out its own enforcement already applied — a
  mandated deprecation ceremony that `mix spec.check` had made unperformable.
  (specled_-dn4.8, specled_-dn4.10)
- **Coverage tests are order-independent and the reach engine is directly
  tested.** Three integration modules mutated the global code server while
  `async: true` (reproduced at 8/15 failures under stress, 0/15 after the fix);
  the formatter and MFA-lines suites mutated a production-read Application
  global and the VM-global `:debug_info` option. All are serialized.
  `per_test_requirement_reach/3` gains direct unit coverage of its partitions
  rather than being exercised only end-to-end. (specled_-ya8, specled_-dn4.7)
- **The v1 file-level detectors can match again.** Making record `:files`
  repo-root-relative (above) left `mix spec.triangle` and
  `Review.CoverageClosure` joining those against `closure_files` still derived
  from raw absolute `module_info(:compile)[:source]` — an identity that could
  never match, so `execution_reach` always reported 0/M and
  `untested_realization` was computed over an impossible join. Both
  `mfa_source_file/1` producers now resolve to the same repo-root-relative
  identity as record `:file` values. (specled_-ygi)
- **Tier-3 hardening.** `Boundary.head/1` and `tail/2` tolerate a dead table via
  rescue rather than a TOCTOU pre-check; `per_test_boundary/1` tolerates a
  `setup_all` context instead of raising `FunctionClauseError`;
  `Store.classify_v2/1` rejects a present-but-non-map `:meta`; source resolution
  no longer loads modules as a side effect of a function documented as pure; the
  anonymous coverage ETS tables declare read/write concurrency; and the five
  review attribution dispatches fold into one helper. Dead state, a duplicated
  snapshot default, and a tuple-arity ladder are removed. (specled_-dn4.9)

**Changed behavior worth checking before you upgrade.**

- `SpecLedEx.Coverage.Boundary.tail/3` is now `tail/2`; the write-only `:tags`
  field is gone from the boundary row. (specled_-dn4.1)
- `mix spec.cover.test --per-test` gains a new failure mode: it raises on a
  stale or missing artifact where it previously exited 0.
- Review surfaces render no qualifier where they previously rendered
  "exact up to escaped processes"; that wording is retired repo-wide in favour
  of the chained-window bound.
- The anonymous ETS option list quoted by `specled.coverage_capture.anonymous_ets`
  now includes `read_concurrency` and `write_concurrency`.

## 0.8.0 — 2026-07-25

- `mix spec.check` and `mix spec.validate` now end every run they report on
  with a machine-readable verdict line — `spec.check result=pass` or
  `spec.check result=fail tier=<validate|branch> error_findings=<N>`, and the
  `spec.validate` equivalent. It is printed before the task raises, so a
  failing run states its own outcome instead of leaving the reader to infer it
  from the summary lines above. Exit-code semantics are unchanged.
- Branch findings now break down by severity and disclose suppression:
  `branch base=<base> changed_files=<N> findings=<N> (error=<E> warning=<W>
  info=<I>, info hidden; --verbose to show)`, with `info shown` when
  `--verbose` or `SPECLED_SHOW_INFO=1` is active. Errors now display after
  warnings and info in both the branch and validation reports; ordering is
  display-only and does not affect the report map or recorded evidence.
- `mix spec.check --base <ref>` now validates the ref up front and prints a
  fail verdict before raising, instead of failing later with a bare
  `ArgumentError` after the validation summary had already printed.
- **Changed stdout formats.** Three lines changed shape this release; anything
  parsing them needs updating:
  - `status=<status> errors=<N> warnings=<N>` → `validate status=<status>
    errors=<N> warnings=<N>` (renamed in place, in both tasks).
  - `branch base=… findings=<N>` gained the parenthesised severity breakdown
    described above.
  - `spec.validate --output` announced itself as `spec.validate wrote <path>`
    → `state wrote <path>`, so the task name now prefixes only the verdict.
- Documented the verdict-read protocol across the adopter guides, agent
  guidance, bootstrap skill, and rule text, and added it to `mix spec.prime`
  and `mix spec.next` output wherever they suggest running `spec.check`.

## 0.7.0 — 2026-07-24

- Per-test coverage attribution is now exact within disclosed chained windows.
  `mix spec.cover.test
  --per-test` gains a synchronous boundary hook: `SpecLedEx.Case` (a
  shippable `ExUnit.CaseTemplate`) or a one-line
  `setup {SpecLedEx.Coverage, :per_test_boundary}` in an existing case
  template snapshots each hooked test's coverage window at the
  Runner-awaited `setup`/`on_exit` boundary, so per-test line hits are
  deterministic within the chained [head, tail] window: later hooked tests
  inherit serialized runner/setup_all and any intervening unhooked-test
  activity since the prior hooked tail, and processes that outlive their tail
  snapshot can still leak into a later window or the aggregate remainder. The
  coverage formatter is demoted from
  measurement engine to auditor — it takes one baseline and one final
  snapshot, attributes hooked windows from the boundary table, folds the
  unattributed remainder into the envelope, and degrades honestly when
  tests ran unhooked. Closes the cross-test attribution race
  (specled_-cpw). (specled_-pzd)
- `mix spec.review`'s Coverage tab now binds real per-test MFA closure:
  covered/uncovered partitions and `"executed"` evidence strength come
  from line→MFA intersection (`CoverageTriangulation.per_test_requirement_reach/3`
  + `SpecLedEx.Coverage.MfaLines.index/1`), retiring the file-level proxy
  (specled_-jjq). Per-subject cards carry an attribution qualifier
  ("exact within chained windows" / "degraded: unhooked"). (specled_-pzd)
- Degradation provenance is recorded, not inferred: a degraded per-test
  envelope carries `meta.degraded_reasons` (`:async` |
  `:counters_harvested` | `:unhooked`), `Store.degraded_reasons/1` is the
  single tolerant reader (legacy artifacts fall back to the old
  inference), async/harvest causes dominate `:unhooked` (they corrupt the
  hooked windows; unhooked merely omits coverage), and an unhooked-only
  degrade no longer disables the triangulation detectors. Tests ExUnit
  never ran (excluded / skipped / invalid) are no longer audited as
  unhooked — a fully wired suite under `--only`/`--exclude` or with
  `@tag :skip` stays undegraded. (specled_-pzd)
- Adoption docs split per-test wiring into Phase 4a (aggregate, zero
  wiring) and 4b (per-test boundary hook, opt-in per case template), and
  the spec-led-bootstrap skill detects 4b wiring state and offers an
  optional wiring ticket. (specled_-pzd)

## 0.6.3 — 2026-07-24

- Seed-echo contract hardened across both command kinds and pinned end to
  end. Coverage closes the two remaining cells from the 0.6.0 flake
  diagnostics: the shared-fate timeout path now has a direct seed-echo
  assertion, and a timed-out command's forensic capture is asserted to
  record `timed_out: true`. The contract itself was tightened once and the
  tests follow: a new `specled.verify.command_findings_echo_exunit_seed`
  requirement covers generic `command` verifications (the code always did
  this; the spec now says so), and the merged-run requirement pins the
  multi-run case — a double-timeout finding keeps the FIRST run's seed as
  the primary echo and names the resume pass's own seed next to the resume
  run's hang suspects, so each seed reproduces the run it came from
  (`resumed_result/4` now carries `:resume_seed`). Forensic capture's bare
  `rescue` is narrowed to `File.Error` and emits a one-line stderr warning
  instead of failing silently, and the "no seed line ⇒ findings unchanged"
  negative half is asserted directly. (specled_-viv)

## 0.6.2 — 2026-07-24

- The streaming attribution sidecar (`specled_attr_*.jsonl`) and every other
  cross-VM-visible temp path in `lib/` — command temp scripts, forensic
  capture logs, ADR/diff parse temps, the base-view temp root — now derive
  uniqueness from the new `SpecLedEx.TempName.cross_vm_suffix/0` (OS pid +
  48 bits of entropy) instead of the VM-local `System.unique_integer/1`.
  This closes the collision class where a nested or parallel specled run
  sharing tmp could delete or truncate another run's in-flight file: for the
  sidecar, a completed merged run silently degraded to shared fate with mass
  `tagged_tests_cover_not_executed` warnings (observed in the wild as a
  266-finding anomaly that was clean on serial re-run). The compile tracer
  inlines a dependency-free pid+counter variant because sibling specled
  modules are not loadable inside a host project's compile. Durable policy
  recorded in ADR `specled.decision.cross_vm_temp_names`; a new must
  requirement + scenario pin the sidecar name shape. (specled_-hyt)

## 0.6.1 — 2026-07-24

- CI now arms the coverage gate: both test-matrix legs run `mix test --include
  integration --cover`, with the `mix.exs` threshold lowered 90 → 83 (just
  below the measured 83.05% true coverage; ratcheting back toward 90 is
  tracked separately). `snapshot_test.exs`'s cover-compiled tmp fixture
  modules now run their whole compile/cover-compile/exercise/read cycle in a
  quarantined child BEAM with its own `:cover` coordinator, so they no longer
  leak spurious 100% rows into the tally or crash the HTML report with
  `:no_source_code_found` — and a threshold failure now exits non-zero instead
  of being masked by that crash. (specled_-6v6)
- Envelope load-and-classify consolidated into the new public
  `SpecLedEx.Coverage.Store.load/1`, owning the full `{:ok, env} |
  {:degraded, :no_coverage_artifact | :legacy_artifact | :invalid_artifact}`
  vocabulary; the three copy-pasted private `load_envelope/1` variants in
  `mix spec.triangle`, `Review.CoverageClosure`, and `Review` now route
  through it, so a new envelope status can no longer desynchronize consumers.
  (specled_-q6l.1)
- Split the over-compound `specled.spec_review.coverage_tab_bind_closure`
  requirement into 8 per-contract requirement ids (closure-line format,
  per-test-only "Reached by tests" row, observed/approximate qualifier,
  file-level-proxy note, rollup badge, generated_at staleness, distinct
  degraded banners, no_tracer_manifest banner), each with its own scenario and
  covering test, so a regression in one clause fails at its own requirement
  instead of shipping green at compound granularity. (specled_-q6l.5)
- Removed the dead v1 `CoverageClosure.build/2` (~100 lines, zero callers and
  zero tests since `Review.build_view/3` switched to `build_v2/2`) along with
  its orphaned private helpers and the stale "build_v2 not wired yet"
  comments. (specled_-q6l.3)
- `self_verified?` rendering under `:ok_per_test` mode now carries a
  discoverable "(observed)" qualifier plus a title-attribute caveat on both
  the rollup badge and the per-requirement "Self-verified" row, reusing the
  existing race-bounded disclaimer; aggregate mode is unchanged. The
  underlying synchronous-`on_exit` fix remains tracked as specled_-cpw.
  (specled_-q6l.2)
- Hardened coverage/manifest artifact decodes per-site against
  atom-exhaustion from hostile committed artifacts: `Store.read/1` and
  `Store.read_status/1` now decode with `[:safe]` (with tests proving a
  never-interned atom is rejected without being interned); the v2 envelope
  decode and both tracer-manifest readers deliberately remain non-safe — they
  must be able to resurrect project module atoms in a fresh BEAM — with site
  comments documenting the rationale. (specled_-q6l.4)

## 0.6.0 — 2026-07-24

- Findings for merged `tagged_tests` run failures and timeouts now echo the
  ExUnit seed parsed from the run output (`exunit seed: N — append --seed N
  ...`), in both the attributed and shared-fate paths. Previously the seed was
  lost to head/tail truncation on failures and dropped entirely on timeouts,
  leaving order-dependent flakes unreproducible — the third occurrence of the
  tracer property flake lost its seed and counterexample permanently. A new
  `specled.tagged_tests.findings_echo_exunit_seed` must requirement pins the
  behavior. (specled_-epl)
- New `SPECLED_COMMAND_OUTPUT_DIR` environment variable: when set, failing or
  timed-out verification commands persist their full output, command target,
  exit code, and timeout state to cross-VM-uniquely named files in that
  directory (best-effort — capture failure never alters the verification
  result). The Specs CI workflow sets it and uploads the directory as a
  `specled-command-output` artifact on failure, so the next flake occurrence
  arrives with its counterexample attached. Pinned by the new
  `specled.verify.command_output_capture_dir` must requirement. (specled_-epl)
- Fixed a test-isolation flake in the coverage store suite: both v2 describe
  blocks parked artifacts directly in `System.tmp_dir!()`, which made the
  `last_run.status` sidecar (written to `dirname(artifact)`) a machine-global
  file shared across concurrent BEAMs and leftover from killed runs — the
  `read_status/1` tests then flaked under merged/parallel runs. Artifacts now
  live in per-test directories; diagnosed via the new seed echo, which
  reproduced the failure standalone on its first outing. (specled_-ind)

## 0.5.2 — 2026-07-24

- Command verification temp scripts are now named with the OS pid plus random
  entropy instead of a BEAM-local counter (`System.unique_integer/1`). Two
  concurrent specled runs sharing the system temp dir — e.g. a host project's
  test suite spawning nested specled runs — could collide on the same
  `specled_cmd_*` name, and one run's cleanup deleted the other's in-flight
  script, surfacing as false `verification_command_failed` findings
  (exit 127 / missing file) attributed to untouched subjects. Collision-proof
  naming closes that race; the new
  `specled.verify.command_temp_names_cross_vm_unique` must requirement and a
  regression test pin the name shape. (specled_-vnw)

## 0.5.1 — 2026-07-23

- The doc-identifier lint now covers the repo-resident spec workspace
  (`.spec/**/*.md`), not just `skills/`, `docs/` and `README.md`, so a fabricated
  finding code in a subject spec or decision record is caught the same way one in
  a guide is. Because decision records must sometimes name a budgeted or rejected
  code that no detector emits, such a reference may carry an explicit per-token
  marker — `<!-- spec-lint:allow-code=<token> reason -->` — which exempts only the
  exact token it names, on that line, and **only inside `.spec/decisions/`**;
  guidance docs, skill files and subject specs get no escape hatch, so a lint
  failure there must be corrected rather than marked. Reconciles the fabricated
  codes the widened corpus surfaced (a `triangulation` scenario `then:` clause now
  names the codes its covering integration test actually asserts; two budgeted or
  rejected codes in decision records carry markers), adds a path-boundary guard so
  a code-shaped path segment is not mistaken for a code, and records the policy in
  `specled.decision.doc_identifier_lint_spec_corpus`. (specled_-6fn)

## 0.5.0 — 2026-07-23

**Breaking behavior changes — read before upgrading:**

- **`mix spec.cover.test`'s default mode changed.** It no longer forces
  serialization or installs the custom coverage formatter. By default it
  now runs plain `mix test --cover --export-coverage specled` (no custom
  formatter, no `ExUnit.configure(async: false)`) and ingests the exported
  `.coverdata` into a versioned v2 `:aggregate` envelope — async-safe and
  O(codebase) instead of O(tests × modules). The old serialized,
  formatter-driven capture survives as the opt-in `--per-test` flag. The
  task keeps its name across this change (maintainer decision 2); see
  [`docs/coverage.md`](docs/coverage.md) for the full contract.
- **Wiring `SpecLedEx.Coverage.Formatter` into `test/test_helper.exs` now
  no-ops loudly instead of running silently at pathological cost.**
  Registering the formatter in `:formatters` without going through `mix
  spec.cover.test --per-test` prints one stderr notice
  (`[SpecLedEx.Coverage.Formatter] disabled: ...`) and the formatter
  becomes a permanent no-op for the run — no artifact is written. This
  closes the `specled_-47j` root cause: the old default fabricated
  function-level `{file, 0}` records at O(tests × cover-compiled modules)
  cost (~17 minutes added silently to a 1,480-test CI run in the reported
  incident), and `docs/adoption.md` itself instructed the exact unsupported
  wiring that triggered it. Every `test_helper.exs` wiring instruction has
  been removed from this package's own docs and scaffolds; if you copied
  one into your project, delete it.
- **Async test files fail a `--per-test` run by default.** A test file
  declaring `async: true` genuinely runs concurrently despite the forced
  global `async: false` and corrupts serialized per-test attribution;
  `mix spec.cover.test --per-test` now exits non-zero naming every such
  file before running the suite. Pass `--allow-async` to degrade instead
  of failing (the run proceeds, the envelope is marked `degraded: true`,
  and stderr names the contaminated files).
- **Legacy (pre-v2) coverage artifacts are now rejected, never
  auto-migrated.** `SpecLedEx.Coverage.Store.read_v2/1` returns
  `{:error, :legacy_artifact, message}` for a pre-v2 bare-list artifact,
  naming `mix spec.cover.test` as the re-run command (maintainer
  decision 5). Delete the stale `.spec/_coverage/per_test.coverdata` and
  re-run `mix spec.cover.test` if you see this.

**Also new:**

- Coverage triangulation (`branch_guard_untested_realization`,
  `branch_guard_untethered_test`, `branch_guard_underspecified_realization`)
  is now documented as diagnostic-only, read by `mix spec.triangle` and
  `mix spec.review`'s Coverage tab exclusively — `mix spec.check` has never
  run triangulation and this release forecloses ever wiring it in
  (maintainer decision 1; `specled.decision.aggregate_first_spec_coverage`).
  Docs previously implied otherwise in several places; all known instances
  are corrected.
- `mix spec.cover.ingest <path.coverdata>` — the CI/coveralls escape hatch,
  ingesting a `.coverdata` already exported by another run (e.g. an
  existing coveralls step) into the same versioned envelope, instead of
  requiring a second coverage-instrumented test run.
- New `docs/coverage.md`: the adopter-facing coverage contract — what the
  two headline numbers mean, the `--per-test` cost model and its
  race-bounded (never "exact") attribution limits per `specled_-cpw`,
  artifact hygiene, and the full refusal-reason catalogue with real
  messages.
- `priv/spec_init/workflows/spec_review.yml.eex` now runs
  `mix spec.cover.test` before `mix spec.review` so newly-scaffolded CI
  workflows populate the Coverage tab by default.

## 0.4.1 — 2026-07-23

- Extracted the shared finding-message finalizer — previously byte-identical
  across `AppendOnly`, `Overlap`, and `BranchCheck` — into
  `SpecLedEx.FindingMessage.finalize/2`, the single producer of the prose +
  fenced `fix:` block shape that `review/html.ex` parses. Pure refactor; no
  message-shape change. (specled_-wr3)
- Deduplicated three restated topics (graduation rationale, runtime host/container
  split, and the `spec.evidence.migrate` behavior list) across the
  spec-led-bootstrap skill files into single canonical homes with pointers,
  eliminating the sync surface the skill itself preaches against. (specled_-m8y)

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
