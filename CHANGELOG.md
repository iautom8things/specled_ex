# Changelog

## 0.15.0 — 2026-08-12

Post-release fast-follow backlog (specled_-i4x): the sixteen findings that
releases 0.11.0, 0.13.0, and 0.14.0 each deliberately deferred, drained as one
epic. No new capability area — this is a release about the gate telling the
truth, in three places where it previously did not.

**Weakening authorization now checks ADR status.** `authorizing_decision/3`
filtered on `change_type` and `affects` alone, so a `superseded`, `rejected`,
or `proposed` ADR suppressed an error-severity weakening exactly as well as an
accepted one. Only accepted ADRs authorize now. This is the change most likely
to surface findings in an existing corpus — see the upgrade note.

**In-place statement rewrites are no longer invisible.** Every append-only
detector keyed on a requirement's id, priority, modal class, or scenario count,
so rewriting a `must` requirement's *statement* while keeping its id passed
silently. `append_only/statement_rewritten` closes that hole at warning
severity. This release emits ten of them against itself.

**Realization baselines stopped over- and under-reaching.** Resolution-path
divergence blocked the entire flat-tier refresh, freezing unrelated comparable
baselines; it is now scoped to the diverged `(tier, mfa)` pair. In the other
direction, silent seeding ran before divergence detection and wrote provenance
labels from whatever the build happened to be, so a cold or stale tree could
record `resolved_via: source` for a binding a warm run resolves from BEAM. That
seed is now gated on the run being divergence-free.

### Added

- `append_only/statement_rewritten` — warning-level finding for a must-priority
  requirement that keeps its id while its statement changes after whitespace
  normalization. Ratified as the twelfth append-only code by
  `specled.decision.append_only_finding_budget_v3` (specled_-vzd.3)
- `SpecLedEx.AppendOnly.finding_codes/0` — the append-only code catalog is now
  derived at compile time from the emitters themselves via a `finding/2` macro
  that registers each literal code, replacing the hand-maintained mirror that
  could drift from what the module actually emits (specled_-bg5.6)
- `docs/security.md` — threat model for repository-authored command execution:
  which tasks execute repo shell by default, what `--no-run-commands` does and
  does not disable, and the fork-PR CI trust policy. Includes the fact that
  `@requirements ["app.config"]` compiles the revision even in the structural
  lane (specled_-bg5.3)
- Command-tier structural guard for the spec-review workflow privilege split:
  deny-by-default allowlists over jobs, permissions, `uses:` actions and their
  `with:` keys, and the deploy checkout's base-ref pin (specled_-vbo)
- Realization comment-pointer lint: long comment blocks under `lib/realization`
  must terminate in an existing `specled.decision.*` pointer rather than
  restating the ADR's prose, with a corpus-scoped exemption marker
  (specled_-vzd.6)
- Bidirectional documentation full-set lint: a region marked
  `spec-lint:full-set=<id>` must enumerate exactly its configured code set, so
  a claim of completeness cannot silently go stale (specled_-vzd.5)
- `SpecLedEx.Coverage.Paths` — one home for coverage source-path identity,
  replacing the duplicated resolution logic (specled_-dn4.12)

### Changed

- Only ADRs with `status: accepted` authorize a weakening (specled_-bg5.4)
- Self-authorization `:info` markers print on default `mix spec.check` output
  instead of requiring `--verbose` or `SPECLED_SHOW_INFO=1`; the marker's
  authorizing-ADR selection is deterministic under input reordering, and one
  marker is emitted per `(requirement, weakening class)`
  (specled_-bg5.5, specled_-bg5.1)
- Resolution-path divergence excludes only its own `(tier, mfa)` entry from
  flat-tier baseline refresh rather than blocking the whole refresh
  (specled_-vzd.2)
- Severity overrides carry their provenance, so a finding reports which layer
  set its severity (specled_-bg5.2)

### Fixed

- A cold or stale build could write a permanently misleading
  `resolved_via: source` label during silent seeding. Seeding now runs after
  tier dispatch and is withheld entirely on any run carrying a resolution-path
  divergence (specled_-vzd.1)
- `HashStore.merge/2` crashed on the default configuration when seeding
  preserved entry envelopes (specled_-vzd.4)
- Coverage source paths resolved inconsistently inside a child BEAM
  (specled_-dn4.12, specled_-bos)
- Formatter lifecycle assumptions were asymmetric between `record_inventory/2`
  and `flush/1` (specled_-zd8)

### Upgrade notes

- **Findings may appear that an ADR previously suppressed.** If a weakening in
  your corpus was authorized by an ADR whose status is not `accepted`, that
  finding returns — at its own severity, which for deletions, modal downgrades,
  scenario regressions, and polarity removals is `:error`. Audit with
  `mix spec.check --verbose` before upgrading in CI. The fix is to set the
  governing ADR to `accepted`, not to re-weaken the spec.
- **Expect new `append_only/statement_rewritten` warnings.** Any `must`
  requirement whose text was edited in place since your baseline now reports.
  These are warnings and do not fail the gate; review them and record the
  rationale in a `clarifies` ADR where the rewrite was deliberate.
- **A divergent run seeds no new baseline entries.** On a tree where any
  binding resolves through a different path than its baseline, newly tracked
  entries are not seeded until a run with no divergence. Compile before the
  first baseline run to avoid the delay.

## 0.14.0 — 2026-08-11

Realization hash integrity (specled_-n5q): two independent defects in the
`api_boundary` binding path, both surfaced by running the guard against a
downstream adopter's corpus. First, `canonicalize_head/1` emits structurally
different envelopes per resolution path — a 4-tuple over all BEAM debug_info
clauses, a 5-tuple over the first parsed def clause on the source fallback —
so the same unchanged function hashes two ways and an uncompiled tree
fabricated plausible-looking realization drift for code nobody touched.
Second, `collect_bindings/2` deduped the tier on MFA alone, so an
implication-inferred subject entry could shadow authored requirement bindings
(suppressing dangling findings entirely for a nonexistent MFA), and authored
entries from different requirements sharing one MFA collapsed into a single
entry with `requirement_id: nil`.

Downstream adopters (voyd_config, builder, atlas) picking up this dep bump get
honest cross-path classification instead of fabricated drift, and per-requirement
provenance on shared MFAs. **Adopters whose corpora carry shadowed dangling
bindings will see NEW dangling findings on upgrade** — that is the defect
surfacing, not a regression; see the upgrade note below.

No `hasher_version` bump and no baseline change: same-path hashes are
unchanged, and the store is MFA-keyed, so entry counts and hash values are
untouched.

### Added

- `branch_guard_resolution_path_divergence` — warning-level finding emitted
  when a labeled baseline entry's `resolved_via` differs from the current
  resolution path. The two paths canonicalize to structurally different
  envelopes, so the hashes are incomparable and the disagreement reports on
  the *environment*, not the code. It blocks baseline refresh in both branches
  (including `--accept-drift`) so an uncompiled tree cannot overwrite
  beam-hashed baselines, and excludes the pair from attestations. The tenth
  guard code; `specled.decision.finding_code_budget` is amended to justify it
  against the budget rather than around it (specled_-n5q.1)
- `resolved_via` (`beam` | `source`) entry metadata on `api_boundary` hash
  store entries, with `Binding.resolution_path/1` classifying the path that
  produced a resolution. Unlabeled legacy entries keep legacy drift semantics
  — "assume beam" was empirically refuted on this repo's own corpus, where
  private-function bindings always resolve via source and their unlabeled
  baselines were therefore source-written (specled_-n5q.1)
- Requirements `specled.api_boundary.same_path_hash_comparison`,
  `path_divergence_finding`, `divergence_blocks_refresh`,
  `divergence_withholds_drift_silencing`, and
  `specled.binding.resolution_path_classification`, with covering scenarios
  (specled_-n5q.1)
- Requirements `specled.realized_by.authored_beats_inferred` and
  `authored_provenance_preserved`, with covering scenarios and executing
  tagged tests (specled_-n5q.2)
- ADRs `specled.decision.resolution_path_provenance` (the design and the
  assume-beam refutation) and `specled.decision.amplification_scoped_dedupe`
  (the design, the corpus measurements, and the adopter-upgrade consequence)
- `SpecLedEx.FixtureCompiler` test support: compiles runtime fixtures with
  `debug_info` forced on, plus an explicit
  `compile_to_path_without_debug_info/2` for the stripped-debug degrade
  (specled_-n5q.1)
- `make test` gains `TEST=` passthrough for targeted runs

### Fixed

- Cross-path hash comparison reported `branch_guard_realization_drift` for
  unchanged code. The detector now compares same-path only; cross-path
  encounters on labeled entries are classified as divergence
  (specled_-n5q.1)
- `--accept-drift` on a run that also emitted a divergence finding downgraded
  real drift to `info` and reported `pass` while the baseline refresh the
  downgrade is predicated on was blocked — so the drift silently resurfaced
  after the branch merged. Divergence now withholds the downgrade on the same
  grounds a dangling binding already did, restoring "silence exactly what you
  heal" (specled_-n5q.1)
- An unrecognized `resolved_via` label (a hand-edit, or a future third path
  met by a pinned adopter) was treated as permanent divergence, which blocks
  the refresh and so froze the entry with no way to rewrite it. Unrecognized
  labels now fall back to legacy comparison. A non-string `hash` no longer
  raises from the comparison path (specled_-n5q.1)
- A `hasher_version` rehash rebuilt entries as a two-key literal, dropping
  `resolved_via` and silently reverting every labeled entry to legacy
  semantics. The rehash now preserves the entry's other keys. Unreachable at
  `hasher_version: 1`, fixed before it becomes reachable (specled_-n5q.1)
- `api_boundary` dedupe is now scoped to what the implication amplification
  actually creates: inferred entries dedupe on MFA among themselves and yield
  entirely to any authored entry sharing their MFA; authored entries never
  collapse by MFA — only exact `{subject, requirement, mfa}` duplicates drop.
  Requirement `implication_amplification_dedup` is rewritten to these
  semantics (specled_-n5q.2)
- Authored bindings on a nonexistent MFA produced zero dangling findings
  corpus-wide when a subject-level inferred entry shadowed them and the
  implementation tier was off (its default) (specled_-n5q.2)
- Test-harness fidelity: Mix's test task disables `:debug_info` for runtime
  compilation, so every runtime-compiled fixture had been resolving via the
  source fallback — the suite never exercised the beam path production uses,
  and `NoDebug`'s `@compile {:no_debug_info, true}` was inert. Fixtures now
  force `debug_info`, and the vanilla beam-first binding test asserts
  `resolution_path(ast) == :beam` (it had been passing through the source
  fallback) (specled_-n5q.1)
- `docs/adoption.md` and `docs/concepts.md` carry the new finding code, so
  their "full set" claims are true again (specled_-n5q.1)

### Upgrade notes

- **New dangling findings are expected** where authored bindings were
  previously shadowed by inferred subject entries. Plan the corpus sweep as a
  deliberate exercise rather than treating the findings as a regression.
- Shared-MFA corpora should expect higher finding volume: findings are now
  emitted per requirement and are not grouped downstream (`Drift.dedupe`
  serves the `:use` tier only and groups by subject), including the
  cross-layer subject+requirement doubling.
- A `branch_guard_resolution_path_divergence` on a cold `_build` is fixed by
  compiling and re-running. For a *permanent* path change — e.g. a bound
  function made private, which resolves via source forever — delete the entry
  from `.spec/realization_hashes.json` and the next clean run re-seeds it
  labeled with the new path. Deleting accepts the current hash unreviewed, so
  confirm the body is unchanged first; the divergence finding never compared
  it.
- **Expect a one-time relabel diff.** The first clean run after upgrading
  adds a `resolved_via` key to every `api_boundary` entry in
  `.spec/realization_hashes.json`. Hash values do not change — in this repo
  all 173 entries kept byte-identical hashes — so the diff is additive noise,
  not drift. Commit it in its own commit to keep it out of review.
- **Upgrade the team together.** An older specled reading a labeled baseline
  ignores `resolved_via` and, on its next refresh, writes entries back
  without it — silently un-labeling what the new version just labeled. Mixed
  versions across a team will churn the file back and forth.
- The divergence block is **run-wide**: one diverged `api_boundary` MFA stops
  the baseline refresh for every flat tier. Setting the code's severity to
  `off` hides the finding but not the block, which yields a frozen baseline
  with no on-screen explanation — fix the cause instead.

## 0.13.0 — 2026-08-06

Same-PR self-authorization visibility + `--debug` crash fix (specled_-q0q /
specled_-s0n). Append-only previously warned only when a new weakening ADR's
`affects` exactly matched the requirements *deleted* in the same diff —
scenario regressions, modal downgrades, and polarity removals could be
self-authorized with no ADR-level warning, and a superset `affects` list could
suppress a deletion without either the warning or a per-requirement trace.
This release admits an informational per-requirement marker for those
suppressions, generalizes same-PR matching to a non-empty subset of all four
weakening classes, and repairs a `BadBooleanError` on `mix spec.check --debug`
when executed `tagged_tests` entries carried a non-boolean truthy
command-result map.

Downstream adopters (voyd_config, builder, atlas) picking up this dep bump get
both the new `append_only/self_authorized_weakening` marker and the `--debug`
fix.

### Added

- `append_only/self_authorized_weakening` — info-level, requirement-shaped
  marker emitted for each deletion, scenario regression, modal downgrade, or
  polarity removal authorized by an ADR authored in the same diff (including
  suppressions by a superset `affects` list that do not qualify for the ADR
  warning). Distinct code from `append_only/same_pr_self_authorization`
  (warning, ADR-shaped) per the one-code / one-severity / one-entity-shape
  discipline (specled_-q0q.2)
- Generalized `same_pr_self_authorization` matching: a new weakening ADR
  qualifies when its non-empty `affects` set is a subset of all requirement
  ids weakened in the same diff across the four classes (removed,
  scenario-regressed, modal-downgraded, polarity-stripped), not only exact
  equality against deleted ids. Empty `affects` never qualifies
  (specled_-q0q.2)
- ADR `specled.decision.append_only_finding_budget_v2` superseding the v1
  twelve-code budget: 11 `append_only/*` + 2 `overlap/*` (13 guardrail codes
  total). The new code is the eleventh append_only emitter
  (specled_-q0q.2)

### Fixed

- `mix spec.check --debug` raised `BadBooleanError` on executed
  `tagged_tests` verification entries whose command result was a map: the map
  sat on the left of a strict-boolean `and` in the debug-checks clause that
  tests for `:attribution`. That clause now guards with
  `is_map(command_result)`; four equivalent truthy-map operands — two on the
  unconditional findings path, two elsewhere in the same debug-checks `cond`
  — were normalized to `is_map/1` alongside it with no behavior change, since
  those values are always nil or a map. `command`-kind entries never raised:
  there the map was the rightmost `and` operand (specled_-q0q.1)
- Stale append-only budget mirrors: `docs/concepts.md` now says eleven codes
  and points at `append_only_finding_budget_v2`; `BranchCheck`
  `@per_code_defaults` mirrors `append_only/self_authorized_weakening` at
  `:info` (specled_-q0q.4)
- `spec_review` HTML "Decisions / governance" row now counts
  `append_only/self_authorized_weakening` so a live finding flips that row;
  hand-maintained catalogs in the review-HTML tests and the
  severity-integration tests assert equality against the AppendOnly
  emitter-derived set (specled_-q0q.5)
- `SpecLedEx.Config.Guardrails` moduledoc: guardrail code count 12→13
  (11 `append_only/*` + 2 `overlap/*`), with provenance "introduced by
  specled_-fm4 and extended by specled_-q0q.2" (fm4 landed the original 12;
  q0q.2 added the eleventh append_only code) (specled_-q0q.6)

## 0.12.0 — 2026-08-05

Dependency-hygiene release (specled_-0o8): the compile-connected xref graph
is now empty and gated. On 0.11.0, nine compile-time edges — schema structs
calling `SpecLedEx.Schema.id()` at compile time, stale unused-alias
suppressors (which also formed two compile-time cycles between
`SpecLedEx.Schema` and its sub-schemas), a module-attribute lookup in the
decision parser, and the case template's setup tuple — made changes to those
targets cascade recompiles. All nine are gone, and `make xref`
(`MIX_ENV=test mix xref graph --label compile-connected --fail-above 0`)
holds the graph at zero edges locally and in CI.

### Added

- `SpecLedEx.Schema.Id` — leaf module owning the id contract consumed at
  compile time by every schema struct; declared in `specled.block_schema`'s
  surface and `api_boundary` (specled_-0o8)
- `make xref` target (MIX_ENV=test pinned for CI parity), wired into the CI
  workflow and the Merge Gates checklist (specled_-0o8)
- ADR `specled.decision.compile_connected_zero` recording the zero-edge
  invariant and the leaf-module convention (specled_-0o8)

### Fixed

- id pattern anchored with `\A`/`\z`: `^`/`$` accepted a trailing newline,
  so `"subject\n"` validated as a legal id. Pinned by new schema tests —
  the api_boundary hash tier covers function heads only and would never
  catch a regression of the pattern (specled_-0o8)

### Changed

- `SpecLedEx.Case` injects its per-test boundary hook via a block-form setup
  calling `SpecLedEx.Coverage.per_test_boundary/1` — the tuple form would
  put the alias in module-body code and create a compile-connected edge.
  `setup {SpecLedEx.Coverage, :per_test_boundary}` remains the documented
  adopter wiring; `specled.coverage_capture.case_template` updated to match
  (specled_-0o8)
- `SpecLedEx.DecisionParser.CrossField` resolves `Decision.weakening_types/0`
  at runtime instead of via a module attribute (specled_-0o8)

### Removed

- `SpecLedEx.Schema.id/0` — dead delegate with zero callers after the Id
  extraction (`@moduledoc false` internal surface) (specled_-0o8)

## 0.11.0 — 2026-07-28

Impromptu epic (specled_-k6s) bundling eighteen independently-surfaced
follow-ups onto one release. The through-line is guards that could not fail: an
exemption marker that a `>` in its own reason text defeated, a decode default
that resurrected atoms for every caller who did not opt out, assertions that
stayed green when the behavior they named was inverted, and prose — in specs,
ADRs, and code comments — asserting properties the code had stopped having.
Every item either replaced a check that could not go red, or retired a claim
that was no longer true.

Expect this release to **flag more than 0.10.0 did**. Several items close
detection holes rather than add features, so a repository that passed
`mix spec.check` on 0.10.0 can legitimately fail on 0.11.0 without changing a
line of its own code.

### Added

- `specled.coverage_capture.decode_atom_policy`: `Coverage.Store.safe_decode/2`
  defaults to `[:safe]`, so no call site receives atom-resurrecting decode
  implicitly. `read_v2/1` opts out explicitly; `read_status/1` keeps the
  fail-closed default. Two positive regression guards — a `read_v2` artifact
  naming a never-interned module atom, and a tracer manifest carrying a foreign
  module atom key — make a future blanket `[:safe]` sweep fail loudly instead of
  silently widening what the reader accepts (specled_-xkn.1)
- `specled.coverage_capture.envelope_meta` gains the read-path rejection rule
  for a present-but-non-map `:meta`, giving the existing `Store` assertion an
  owning clause. The `write_v2/2` clause from specled_-n5s is unchanged
  (specled_-npo)
- The verifier's reserved `repo.` affect-namespace exemption is documented in
  `specled.decisions.decision_governance` and mirrored by a CrossField R4
  filter, so wiring CrossField into the live parse path will not red-gate corpus
  ADRs carrying `affects: repo.governance`. Pinned in both directions — a
  `repo.`-namespaced affect resolves clean, a genuinely missing subject still
  reports `cross_field/affects_unresolved`
  (`specled.decisions.cross_field_affects_resolve`, specled_-14t)

### Fixed

- The stale-allow-marker sweep had two evasions, both now closed by unifying
  exemption and strip on one HTML-comment-wrapped grammar: a `>` character
  inside a marker's own reason text terminated the strip early and defeated it,
  and bare unwrapped `spec-lint:allow-code=` prose granted an exemption it was
  never meant to grant. `specled.package.doc_identifier_integrity` now names the
  wrapped form explicitly. A marker naming a non-guarded code reports as
  unnecessary with its own message rather than borrowing the outside-marker one
  (specled_-ozm)
- `mix spec.validate` argument pre-flight adopts `TaskArgs.validate/3` and
  reports `tier=usage` on unknown-flag rejection, with an explicit `:tier`
  required in the failing `print_verdict` path. The verdict grammar is
  reconciled so `spec.validate` admits `tier=<usage|validate>` (specled_-wby)
- `lib/mix/tasks/spec.triangle.ex` carried a comment claiming the MFA-level
  untested-realization gate reads `binding_present?` and must keep flagging it.
  No gate in that task's call graph does — aggregate findings are filtered to
  `detector_unavailable`, and the v1 legs join on `closure_files`. The comment
  now states the truth, and the producer is pinned at the unit level against
  `CoverageTriangulation.envelope_findings/3` rather than through the task
  (specled_-b23)
- `.spec/specs/triangulation.spec.md` asserted as a standing claim that "the v1
  functions and `mix spec.triangle` are unchanged", which the
  `v1_file_level_path_identity` requirement had since contradicted. Reworded to
  past tense scoped to the v2 addition. The same requirement now states the
  unloadable-module posture explicitly: a closure module failing
  `Code.ensure_loaded/1` contributes no closure file, and in both that case and
  the out-of-repo case the binding dangles — a dangling-binding concern, not
  evidence of a missing test (specled_-b23)
- `specled.decision.cross_vm_temp_names_reach` replaced its bare "test-only
  usages remain fine" sentence with an accepted-risk carve-out: VM-local
  `unique_integer` roots under `System.tmp_dir!/0` in `test/` are not
  safe-by-construction — the nesting hazard is identical to `lib/` — but the
  blast radius is a flaked test. The permission does not extend to tests that
  assert on directory contents or glob-delete in a shared directory, and the
  ADR prescribes by class: allocate-own-root uses
  `SpecLedEx.TempName.cross_vm_suffix/0`, while read/sweep of a genuinely
  shared directory filters on the writer's `System.pid()` prefix, because a
  fresh CSPRNG suffix cannot match names another writer produced (specled_-ehv)
- `specled.verify.command_output_capture_dir` requires cross-VM uniqueness via
  `SpecLedEx.TempName.cross_vm_suffix/0`, matching the accepted
  `command_temp_names_cross_vm_unique` wording so the forensic-capture pointer
  target is complete. The three re-narrated rationale blocks in `Verifier` are
  reduced to one-line pointers at `SpecLedEx.TempName`, leaving the moduledoc as
  the single narrative (specled_-chb)
- `specled.verification.findings_echo_exunit_seed` and its covering scenario
  dropped their placement over-claims: the requirement now asserts only what the
  multi-run pairing test proves — a primary seed from the first run and a
  distinctly labelled resume seed with its own `--seed` hint, never the primary
  — rather than positional adjacency (specled_-zek)
- `specled.decision.doc_identifier_lint_spec_corpus` dropped four absolute
  corpus occurrence counts that drift by construction, keeping the load-bearing
  comparative claim. Dangling `specled_-vk0` forward pointers are cleared now
  that the ticket is closed (specled_-4pl)

### Changed

- The CI coverage threshold moves 83 → 82, with per-leg measured totals and the
  reason the legs differ recorded next to `test_coverage:` in `mix.exs` as the
  single source of truth. The previous 83 left ~0.68pp of headroom, which is too
  thin: ordinary suite changes that `:code.purge`/`:code.delete` cover-tracked
  modules drop them from **both** numerator and denominator of the `--cover`
  tally and can erase sub-1pp margin (specled_-xkn.2)
- `mix.exs` sources the project version from the `VERSION` file rather than a
  literal. It had declared `0.2.0` while `VERSION` and the CHANGELOG both
  tracked `0.10.0`; nothing read either value, so the stale literal was inert
  rather than wrong in effect, but two disagreeing sources of truth is precisely
  the defect class this project exists to catch
- Falsifiability sweep across the suite: assertions covering
  `coverage_no_debug_info_distinct_note` and `coverage_unresolvable_source`
  (specled_-ako), `merge_edges` value provenance for non-session callers
  (`specled.compiler_tracer.merge_on_flush`, specled_-asb), the concepts
  content-lint helpers (specled_-yds), and `Store.load/1` sidecar isolation
  (specled_-26g) each stayed green under mutations that inverted the behavior
  they named. Every one was re-pinned and its mutation proof recorded in the
  commit
- The phase-0 done-criterion in the packaged agent guidance requires
  `--verbose`, because bare `mix spec.check` hides info-level findings and the
  criterion could not otherwise be evaluated (specled_-z5t). Always-loaded rules
  now point at the armed gate wrapper (`bash ./scripts/check_specs.sh` /
  `make check`), so cwd-based rule discovery reaches sessions that
  `settings.json` cannot (specled_-4f7)
- `bw list --grep` is documented as a literal substring match, not a regex. The
  previously documented `Advances:.*<id>` form matched the characters `.*`
  literally and silently returned zero tickets for every subject (specled_-pii)

## 0.10.0 — 2026-07-27

Gate forensics: a verification run that fails or times out now leaves behind
enough evidence to diagnose it without reproducing it. Three flake
investigations in this repo hit the same wall — the run that failed was the
only run that failed, and nothing survived it. Recorded as
`specled.decision.gate_failure_forensics` (specled_-td7).

### Added

- Failing-test and hang-suspect descriptors carry the formatter's event id
  alongside `file:line`: `test/a_test.exs:42 (AlphaTest.test hangs)`. A line
  number is only valid against the tree that ran, so a session editing test
  files between gate runs produces a report that points at a different test —
  or at blank space — with nothing to say which. The id does not shift, so a
  mismatched pair is self-diagnosing
  (`specled.tagged_tests.descriptors_self_identify`, specled_-td7)
- Command-verification captures record the provenance of the tree that
  produced them: the verification root's git HEAD and its dirty path list at
  run time, the list bounded with the omitted count stated. Makes
  report-versus-inspection tree skew detectable rather than a matter of git
  archaeology. A root whose HEAD cannot be resolved — not a work tree, an
  unborn branch, or git absent — is recorded as unavailable rather than
  omitted (`specled.verify.command_capture_run_provenance`, specled_-td7)
- A merged `tagged_tests` run that fails or times out preserves its streaming
  attribution artifact beside the output capture under the same basename,
  instead of deleting the run's only per-test record with the rest of its temp
  files (`specled.tagged_tests.failed_run_preserves_attribution_artifact`,
  specled_-td7)
- `SPECLED_COMMAND_OUTPUT_DIR` is now armed by every gate path this repo owns:
  `make check`, `scripts/check_specs.sh`, and agent shells via
  `.claude/settings.json`. It was unset in every environment where the observed
  flakes actually occurred, which is why no failure output was ever captured.
  The capture itself stays opt-in — a library must not write to a consuming
  project's filesystem uninvited (specled_-td7)
- `specled.coverage_capture.write_v2_argument_error_contract`: every
  malformed-envelope rejection in `Store.write_v2/2` raises the `ArgumentError`
  the function documents, never a substitute type (specled_-n5s)

### Fixed

- `SpecLedEx.Coverage.Store.write_v2/2` raised `KeyError` for an envelope
  lacking `:meta`, from a function whose docs promise `ArgumentError` — an
  exception no caller following the docs would catch. `:meta` is read with
  `Map.get/3` rather than added to `@v2_required_fields`, because that list
  also gates `classify_v2/1`, where requiring it would reject every
  pre-Stage-1 artifact the read path is specified to tolerate (specled_-n5s)
- `test/test_helper.exs` unsets `SPECLED_COMMAND_OUTPUT_DIR` for the suite.
  The suite fails verification commands on purpose, so an inherited capture
  directory buried the one genuine capture under deliberate ones. The count
  before depended on test order — the first capture-exercising test to finish
  unset the variable for everything scheduled after it — and reached 30 files
  in a single module run; it is 0 at every seed now. The capture that matters
  is written by the outer `mix spec.check` run, not by the suite about its own
  fixtures (specled_-td7)

### Changed

- Finding messages naming failing or hung tests are longer by one
  parenthesized test id per descriptor. Consumers matching the bare
  `file:line` prefix still match; anything anchoring the end of a descriptor
  does not (specled_-td7)

## 0.9.6 — 2026-07-26

Impromptu epic (specled_-233) bundling five independently-surfaced follow-ups
onto one PR. The through-line is falsifiability: each item replaced a guard that
could not fail — an existence check standing in for a content check, a `must`
whose only verification was blind to it, an ADR asserting reach it did not have,
and a build-staleness test a same-second edit defeated.

### Fixed

- `specled.package.concepts_guide` moved off existence-only `source_file`
  verification onto an `execute: true` tagged_tests content lint, so the clauses
  the requirement names — the spec triangle, the `realized_by` tiers, the
  graceful-degrade `detector_unavailable` rule, and all three drift-acceptance
  paths — can no longer be deleted with the gate green. Each needle is unique to
  its section, because bare identifier tokens were satisfied incidentally by
  unrelated prose elsewhere in the document (specled_-48i)
- The over-compound `specled.spec_review.coverage_tab_bind_closure` requirement
  is retired: its eight per-contract children now own the prose, and the eight
  `# covers:` markers across `lib/` and `test/` point at the split id each call
  site actually implements. The surviving id carries a concrete, falsifiable
  `per_requirement_reach/2` data contract instead of a statement-free umbrella,
  and a `:no_debug_info` render contract that had been dropped without
  restatement is restored as its own requirement — the
  `specled.decision.coverage_identity_joins` consequence that depended on it is
  no longer orphaned (specled_-gai)
- The last fixed-name write-rename sibling in `lib/`
  (`.spec/realization_hashes.json.tmp`, built by `Realization.HashStore`) now
  derives its uniqueness from `SpecLedEx.TempName.cross_vm_suffix/0`, so
  `specled.decision.cross_vm_temp_names` is no longer contradicted by an
  unconverted, unexcepted site. The compiler tracer's pid-separation guarantee
  is now falsifiable — a test fails when `System.pid()` is dropped, pinning the
  actual pid value rather than a digit class, which a VM-local counter satisfied
  before. A superseding ADR reconciles the declared reach in both directions
  across seven governed subjects, with `specled.evidence_store` explicitly
  excluded and justified rather than silently omitted (specled_-ymn)
- `bootstrap_tracer!` could run a permanently stale tracer beam. Staleness was
  decided by `src.mtime > beam.mtime`, and `File.stat!/1` mtimes have
  one-second granularity — so an edit or a `git checkout` revert landing in the
  same second as the previous compile left the comparison false and a mutated
  artifact fresh indefinitely. Unrecoverable in practice, because the tracer
  source is excluded from `elixirc_paths/1` (a module cannot trace its own
  recompilation) and `mix compile --force` therefore never rebuilds it; the
  symptom was a clean working tree running stale code. Staleness is now keyed on
  the source content **and** the compiling toolchain, the latter because a beam
  is loadable only by a compatible OTP and a matrix-leg switch leaves an
  artifact whose source is byte-identical (specled_-pr6)

### Added

- The doc-identifier lint gains five guards, each falsifiable in the direction
  it protects: the token patterns' `(?<![\w/])` lookbehind is pinned in both
  directions, so neither tightening nor loosening it can silently change
  coverage; `severity_corpus/0`'s deliberate `.spec/**` exclusion is asserted on
  both arms; guarded codes are asserted digit-free, with that decision recorded
  in the governing ADR rather than left implicit; stale allow-markers are swept
  for both rot directions (a token that has become a real emitted code, and a
  token no longer present on its line); and the hand-maintained `@known_codes`
  mirror now fails on a code **deleted** from `lib/` as well as one added, so
  docs naming a dead code no longer pass (specled_-vk0)

### Changed

- `specled.package`'s `decisions:` list now names
  `specled.decision.doc_identifier_lint_spec_corpus`, so the must that states
  which finding-code families are mechanically guarded has an in-corpus pointer
  to where the deliberate non-guarding of the rest is justified (specled_-vk0)

## 0.9.5 — 2026-07-26

Fast-follow slice of the spec.check verdict-contract + teaching-sweep epic
(specled_-0x4): the remaining pre-ship critical-review findings and the
hj4-verifier doc/skill accuracy items, landed as one PR.

### Fixed

- `mix spec.check` pre-flight rejections (unknown arguments, invalid
  `--min-strength`, bad `--base`) now report `tier=usage` instead of falsely
  claiming `tier=validate` on runs where validation never started; the
  verdict-grammar requirement documents what `error_findings=0` means on a
  fail verdict, and the formerly identical test pins now assert distinct
  verdicts (specled_-0x4.2)
- `mix spec.validate`'s min-strength pre-flight rejection likewise reports
  `tier=usage` (specled_-wli)
- Bootstrap skill: `detector_unavailable` probe instructions now include
  `--verbose`, so the info-level findings adopters are told to look for are
  actually visible on stdout (specled_-xde)
- Bootstrap skill: `task-templates.md` no longer instructs replacing a
  nonexistent `<PROJECT_VERIFICATION_COMMAND>` placeholder in the scaffolded
  AGENTS.md (the line must be added), and its workflow-template and
  security-note claims were corrected against the shipped
  `priv/spec_init/` templates (specled_-0x4.4)

### Changed

- One shared `--base` validator (`SpecLedEx.BranchCheck.validate_base/2`) now
  backs both `mix spec.check` and `BranchCheck`, removing logic-for-logic
  copies that could silently diverge; `TaskArgs` gains a non-raising
  `validate/3` so verdict-print and raise derive from one evaluation; both
  tasks' `print_verdict/2` read options order-insensitively via
  `Keyword.get/3` (specled_-wli)
- The `specled.tasks.verdict_line` requirement now enumerates every
  verdict-emitting path explicitly and names the excluded pre-report raise
  paths, replacing the circular "where the task itself reports a verdict"
  scope clause (specled_-0x4.3)

### Added

- Golden literal test pinning the verdict read-protocol sentence, so a
  unilateral edit to the shared constant fails a test; plus an
  `execute: true` doc verification binding `docs/adoption.md` and
  `docs/concepts.md` to the exact sentence (specled_-0x4.1)
- Level-preserving `drain_shell_events/0` test helper with pass- and
  fail-path `{:info, verdict}` assertions; a three-severity display-ordering
  proof in one run of the mixed fixture; and verdict-contract test
  attribution aligned with the tests that actually prove it — including the
  previously uncredited `tier=branch` form (specled_-0x4.3)

## 0.9.4 — 2026-07-26

Test-only hardening of the third flake class in the `mix spec.check` gate
path: the load-fragile tagged_tests leg, which red-lighted only when the
machine was busy — i.e. during parallel orchestration, when a red gate is
most expensive. No `lib/` changes; the diff is two test files. The final
shape survived a cold verify/audit cycle that twice narrowed it (a global
ExUnit timeout raise and two preemptive module deadlines were rejected as
evidence-free blast radius). (specled_-odl)

- The two ticket-named modules, `SpecLedEx.VerifierTest` and
  `SpecLedEx.ReviewTest`, get a module-scoped 2-minute ExUnit deadline
  (`@moduletag timeout:`) instead of the default 60s: under machine load,
  their subprocess-heavy tests (nested verifier runs spawning shell shims,
  git-backed fixtures) slow down far more than CPU-bound ones, and the 60s
  kill converted load into gate failures. The rest of the suite keeps the
  tighter runaway-regression deadline.
- The seven timeout-classification shim budgets in `verifier_test.exs` are
  consolidated into a single `@timeout_shim_budget_ms` attribute at the
  module top and widened 2000ms → 4000ms — d300c21 set 2000 as the margin
  for the three-level spawn race (Port → sh → setsid sh → shim) and a
  loaded gate run still lost that race. The attribute's comment records the
  true wall cost: five of the seven sites pay 2× the budget because their
  resume pass also times out (~48s of deliberate sleep per full run).
- `SpecLedEx.ReviewTest` runs serially (`async: false`) to keep its per-test
  git spawns out of the async phase's fork burst; the comment states the
  mechanism as inferred and unreproduced, and nothing in the module requires
  serialization for correctness.
- Not closed by this release, deferred with rationale to specled_-td7:
  `verifier_test.exs:1452` (no credible mechanism — no tight budget, nothing
  to race, already-serial module) and the `docs_identifier_lint_test.exs:255`
  reporting anomaly (a failing-test line that maps to no test declaration on
  the tree that ran). td7 adds self-identifying failure descriptors and
  gate-environment forensics (`SPECLED_COMMAND_OUTPUT_DIR`) so the next
  occurrence is diagnosable instead of another guessing round.

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
