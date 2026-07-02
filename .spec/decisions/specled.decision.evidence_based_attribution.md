---
id: specled.decision.evidence_based_attribution
status: accepted
date: 2026-07-02
affects:
  - specled.tagged_tests
  - specled.verification
---

# Evidence-Based Per-Cover Attribution for Merged Tagged-Tests Runs

## Context

The merged tagged_tests design (one aggregated `mix test` run for every
`kind: tagged_tests` verification) deliberately traded blame granularity for
run cost: a single result is distributed to every participating subject, so
one slow or red run reddens all of them identically. The 2026-07-02 incident
(ticket specled_-s65.3) showed the failure mode in practice: a timed-out run
rendered as 59 identical `verification_command_failed` findings, and LLM
agents — the primary consumers of `mix spec.check` output — misread "all
verifications failed" as a broken codebase. A timeout at 99% suite completion
destroyed 100% of the information the run had already produced.

The ground truth was available the whole time: every participating test
carries `@tag spec: <cover-id>`, and ExUnit formatters observe each test's
start, finish, and pass/fail state with its tags at runtime.

## Decision

1. **Streaming evidence artifact.** The merged run loads
   `SpecLedEx.TaggedTests.Formatter` (shipped in lib/, loadable in host
   projects because specled is a compiled dep) alongside
   `ExUnit.CLIFormatter`. The formatter appends one line-flushed JSONL event
   per spec-tagged test (`test_started`, `test_finished` with state, and
   `suite_finished`) to a path passed via the `SPECLED_ATTRIBUTION_PATH`
   env var. Unset path → formatter no-ops.

2. **Per-claim evidence replaces shared fate.** When the artifact is
   readable, the verifier distributes per-cover-id observed outcomes:
   covers with a recorded pass and no recorded failure reach `executed`
   strength even when the run as a whole was killed; covers with recorded
   failures redden exactly their subjects; started-but-unfinished tests are
   named as hang suspects in the timeout finding.

3. **Silent covers are discriminated by `suite_finished`.** On a run with no
   `suite_finished` event, a cover with no recorded events is a *timeout
   remainder*: it inherits the run's red fate, stays `linked`, and is the
   input set for the resume pass. On a completed run (`suite_finished`
   present), a silent or skipped/excluded-only cover is *runtime-excluded*:
   it stays `linked` and receives the warning finding
   `tagged_tests_cover_not_executed`; it is not resumable (re-running the
   same exclusion changes nothing). The two silences have opposite remedies
   (rerun with fresh budget vs fix the exclusion), so collapsing them would
   reproduce the information destruction this decision exists to fix.

4. **`executed` requires positive evidence when an artifact is present.** A
   completed green run with a silent cover id yields `linked` +
   `tagged_tests_cover_not_executed`, where it previously yielded a silent
   `executed`. Exit 0 is not evidence for a test that provably never ran;
   surfacing silently-excluded spec coverage is the point.

5. **Strict degradation.** Artifact absent or unreadable (old host, compile
   error before ExUnit started, formatter flag rejected, zero parseable
   lines) → behavior identical to shared-fate distribution: every claim
   receives the run's exit code, `executed` means aggregated exit zero. The
   `kind: command` per-spec path is untouched.

6. **Resume pass over the remainder.** After a timed-out merged run with a
   readable artifact and a non-empty never-started remainder, the verifier
   runs exactly one resume command over the remainder's backing files with a
   fresh timeout budget, merging attributions (first-run observed outcomes
   win). Hang suspects are deliberately excluded from the resume so a
   hanging test cannot burn the second budget; a repeat timeout names the
   suspect test ids as the likely problem.

7. **No fourth strength tier.** Both silent-cover classes stay at `linked`,
   preserving the three-level `claimed < linked < executed` vocabulary.

## Consequences

- One timed-out run no longer erases the evidence of everything that passed
  before the kill; findings name the specific hang suspects and count the
  remainder instead of fanning one failure out to N subjects.
- Runtime-excluded tagged tests become visible: previously-green
  `spec.check` runs can turn yellow (`linked` + warning), or red under
  `min_strength: executed`. This is deliberate and user-approved; hosts that
  want the old behavior can simply not set an exclusion that silences
  tagged tests.
- The verifier must kill the command's whole process group on timeout
  (already mandated by `specled.verify.command_timeout_enforced`); an orphan
  child appending to the artifact after the kill would corrupt attribution
  and interleave with resume runs.
- A new warning finding code (`tagged_tests_cover_not_executed`) enters the
  finding-code budget.
- The formatter transport (env var + JSONL + dual `--formatter` flags) is
  ExUnit-version-sensitive only through the stable formatter event API
  (Elixir ~> 1.18 project floor).
- Implementation refinement (2026-07-02): the degradation-vs-compile-cost
  discriminator is the *existence* of the artifact file, not merely its
  parseable-line count. `read_artifact/1` returns `:absent` only for a missing
  or unreadable file (the formatter transport never engaged: old host,
  rejected `--formatter`, or a compile error before ExUnit loaded), and
  `{:ok, events}` for any readable file — `events` may be empty. An empty but
  present artifact on a timeout therefore stays on the evidence path (all
  covers `:not_started`) and yields the "timed out before any test started —
  likely compile cost" hint, while a missing artifact degrades byte-for-byte
  to shared fate. This keeps the strict-degradation contract intact (missing
  file → today's behavior) while making the compile-cost signal reachable.
- Implementation refinement (2026-07-02): ExUnit collapses a test's multiple
  `@tag spec:` declarations (and any `@moduletag spec:` list) to a single
  effective tag at runtime, so a cover declared only via a shadowed tag never
  appears in the recorded `spec` list even though its test ran. Attribution
  therefore also credits a cover by test *location*: the verifier passes the
  scanner's `{file, line}` map, and a passing event at a cover's mapped
  location counts as positive evidence. A genuinely skipped/excluded test at
  that location still reads as runtime-excluded, preserving the point of the
  feature. Because the merged run is dogfooded through this repo's own strict
  `mix spec.check` — a mix-tooling library whose tests spawn `mix`
  subprocesses — the formatter also consumes and unsets `SPECLED_ATTRIBUTION_PATH`
  on init so nested test-spawned runs cannot inherit it and pollute the parent
  artifact with extra events or a spurious `suite_finished`.
