# Concepts

<!-- covers: specled.package.concepts_guide -->

This document explains *why* SpecLedEx looks the way it does. It is the
orienting read for maintainers, new contributors, and agents that need to
reason about the system rather than just run its commands. The command
reference lives in [`README.md`](../README.md); the adoption walk-throughs
live in `docs/adoption.md`.

## Premise: agent-assisted, repo-resident

Two assumptions shape every design decision:

1. **Agents are in the loop.** SpecLedEx is built for Elixir projects where
   an LLM agent helps author code, tests, specs, and decisions. The system's
   job is to give the agent — and the human reviewing the agent — a
   repo-resident source of truth they can both grind against. "Could a human
   read this without tooling?" is never the deciding question; "does this
   help the agent stay grounded in repository evidence?" is.
2. **The specs live in the repo, not a wiki.** Subject specs
   (`.spec/specs/*.spec.md`), durable decisions (`.spec/decisions/*.md`),
   and state (`.spec/state.json`) are version-controlled artifacts that
   diff alongside the code. There is no in-flight proposal folder and no
   separate timeline: Git is the time dimension, `.spec/` is the current
   truth.

Everything that follows — the triangle, the tiers, the findings vocabulary,
the graceful-degrade rule — is a consequence of those two assumptions.

## The triangle

A spec subject, the code that realizes it, and the tests that exercise it
are three corners of a triangle. Each *side* of the triangle is a binding:

```
                 specs
                /     \
               /       \
     @tag spec:        realized_by:
     (subject.req)     (MFAs per tier)
             /           \
            /             \
         tests ---------- code
              per-test coverage
              (MFA → test mapping)
```

- **Specs ↔ Code** is authored as `realized_by:` on the subject's
  `spec-meta` block (and optionally overridden per-requirement). It is a
  typed pointer into the code: "this subject's api boundary is these MFAs;
  its implementation is those MFAs; its macro-expanded behavior is over
  there."
- **Specs ↔ Tests** is authored as `@tag spec: "<requirement.id>"` on an
  ExUnit test (or `@moduletag spec: [...]` at the module level). The test
  is making a claim: "I exercise this requirement."
- **Code ↔ Tests** is observed, not authored. `mix spec.cover.test` runs
  the suite with a custom ExUnit formatter that snapshots per-test line
  coverage and writes it to `.spec/_coverage/per_test.coverdata`. From
  that, SpecLedEx can answer "which tests reached MFA `M`?" and
  "which MFAs did test `T` touch?".

When all three sides agree, you have triangulated proof: the spec claims a
behavior, the code binding points at real MFAs, a test tags the
requirement, and coverage confirms the test actually executed the MFAs
inside that binding's closure. When the sides disagree, the disagreement
has a name, and that name is the finding code.

### Why three sides instead of one

Earlier iterations of the branch guard used a single side — "the user
edited `lib/foo.ex`, which is listed in subject `foo`'s `surface:`, so
require a spec update." That rule is structurally too blunt. It fires on
cosmetic refactors, typo fixes, and test-only changes; it is silent when
behavior changes through a macro provider the user never directly edited.
The triangle replaces *filesystem evidence* with *compiler evidence plus
execution evidence*, and the two are cross-checked against the authored
claim.

## The five tiers

The `realized_by:` binding is tiered because "this MFA realizes the
subject" is not one question — it is five, each with different cost,
fragility, and signal quality. A subject declares only the tiers it
wants to opt into; tiers degrade independently.

| Tier                  | What it hashes                                                         | What it catches                                                                  |
|-----------------------|------------------------------------------------------------------------|----------------------------------------------------------------------------------|
| `api_boundary`        | Function head, arity, arg pattern shape, literal default arguments.    | Surface drift: arity change, arg pattern change, new required arg.               |
| `implementation`      | Transitive call closure of the declared MFAs, bounded by subject ownership. | Behavior drift inside the subject's code, composed by hash-ref across subjects.  |
| `expanded_behavior`   | Post-macro-expansion AST from `:beam_lib.chunks(..., [:debug_info])`.  | Drift in `use`-generated functions when the provider changes.                    |
| `use`                 | Provider's `expanded_behavior` hash + sorted consumer module list.     | Drift in macro providers; collapses fan-out to one finding via root-cause dedup. |
| `typespecs`           | Sorted `@spec` / `@type` declarations.                                 | Type signature drift independent of body changes.                                |

A few invariants hold across all tiers:

- **Canonicalization before hashing.** Local-variable renames, whitespace,
  line-number shifts, and function reorderings do not change a tier hash.
  If a cosmetic refactor produces a drift finding, that is a canonicalizer
  bug, not a true positive.
- **Subject-boundary stops for `implementation`.** The call-closure walk
  stops when it reaches an MFA owned by a different subject. The other
  subject's *hash reference* is included in the walker's hash input
  instead of its canonical AST. This is the Cargo-style composition rule:
  when subject B changes, subject A's implementation hash flips via the
  reference, and drift findings dedupe to the root cause.
- **Graceful degrade is first-class.** Umbrella projects, modules compiled
  with `@compile {:no_debug_info, true}`, stripped releases, missing
  coverage artifacts — all of these produce a `detector_unavailable`
  finding with a reason, and the tier silently skips. The system never
  guesses from partial data.

## How a tier detects drift

Each tier produces a **hash**: a short fixed-size fingerprint of whatever
that tier is watching. The fingerprint is computed by canonicalizing the
tier's input (to strip irrelevant details like whitespace, local-variable
names, and line numbers) and then running a deterministic hash over the
canonical form.

The lifecycle has three steps:

1. **Compute.** For every MFA a subject binds to in a tier, SpecLedEx
   reads the current code — source AST for `api_boundary` and
   `implementation`, BEAM debug-info AST for `expanded_behavior`,
   `@spec` declarations for `typespecs` — canonicalizes it, and hashes
   the result. Each `(subject, tier, MFA)` triple produces one hash.
2. **Commit.** The hash is written to `.spec/state.json` alongside the
   binding. A committed hash is the author's signed-off snapshot:
   "this is what the subject realizes, as of this commit."
3. **Compare.** On the next run, the hash is recomputed from current
   code. If the new hash matches the committed one, the tier is quiet.
   If they differ, the tier's view of the subject changed since the
   committed snapshot, and a drift finding names the subject, tier, and
   MFA.

"Tier hash" in the rest of this document means "the hash for one subject
on one tier at one point in time." Drift is always a comparison between
two of those — the committed one and the current one.

Canonicalization is what makes drift findings trustworthy. If a
whitespace edit flipped a hash, every cosmetic change would produce
noise and the user would stop reading the output. The "cosmetic refactors
must not drift" invariant from the previous section is, in practice, the
canonicalizer's job: when it fails, the fix is to strengthen the
canonicalizer, not to weaken the check.

One composition detail is worth flagging because it shows up in finding
messages. For the `implementation` tier, when a subject's call closure
reaches an MFA owned by *another* subject, the walker does not inline the
other subject's AST — it mixes the other subject's committed hash into
its own hash input. So when subject B changes, subject A's implementation
hash flips via that reference, and the dedupe step ([`Drift.dedupe/2`])
collapses the cascade to a single root-cause finding naming B. This is
the "Cargo-style" composition rule that lets a 200-subject repo stay
legible when one widely-referenced subject shifts.

[`Drift.dedupe/2`]: ../lib/specled_ex/realization/drift.ex

## Finding vocabulary

When the three sides disagree, the name of the disagreement tells you
which side is wrong. The finding codes are the user interface — they
are chosen to be diagnostic, not exhaustive. The full set is in the
relevant spec files; these are the ones a maintainer needs to
recognize.

### Reading a finding

Three meta-questions hover over every code in the catalog:

- **Is something wrong?** Sometimes, but not always in the "the build
  is broken" sense. A finding names a *gap* between two sides of the
  triangle. The gap might be a coding bug, a stale spec, a missing
  test, a deliberate weakening that needs an ADR, or a placeholder
  that nobody got around to claiming. The finding does not prescribe
  the reaction; it gives the reaction a name.
- **How does an agent know what to do?** Every finding carries a
  structured payload — subject id, tier, MFA(s), affected file(s),
  test name when relevant — and a message that describes the gap in
  plain English. The append-only and overlap finders additionally
  emit a code-fenced `fix:` line listing the canonical remediation
  paths for that code. For drift and triangulation findings the agent
  reasons from the payload plus the diff: was this a refactor, a
  behavior change, or a tagging mistake? The finding gives the agent
  a vocabulary; the agent still has to think.
- **Where does the surrounding tooling fit?** Each tool plays a
  defined role:

  - `mix spec.check` runs every detector and writes the unfiltered
    set to `.spec/state.json`.
  - `mix spec.next` orders unresolved findings into a single
    recommended next step.
  - `mix spec.validate` surfaces within-spec findings (overlap, prose
    thresholds) without needing a base ref.
  - `mix spec.cover.test` produces the per-test coverage artifact
    triangulation reads; without it that tier degrades to
    `detector_unavailable`.
  - ADRs in `.spec/decisions/` authorize weakenings; `Spec-Drift:`
    commit trailers signal author intent on a per-PR basis;
    `.spec/config.yml` re-prices severities project-wide.

  Severity is policy; the finding code is structural.

The remedies below are *typical*, not exhaustive. Every finding can
also be silenced by a matching `Spec-Drift:` trailer or downgraded
via `.spec/config.yml` when the project has decided that, for now,
this code is informational rather than a hard fail. Re-pricing a
finding is a legitimate act; ignoring one without re-pricing it is
how spec corpora rot.

### Drift findings (code-side disagreement)

These say: *the code moved, but the subject's snapshot did not move
with it.*

- `branch_guard_realization_drift` — For some `(subject, tier, MFA)`
  triple, the hash recomputed from current code does not match the
  hash committed in `.spec/state.json`. The canonicalizer already
  absorbed cosmetic changes, so a drift finding means something the
  tier cares about actually moved — and the subject has not been
  updated to acknowledge it.

  **Remedy paths** (distinguished by intent):

  - **Behavior intentionally changed.** Update the subject spec — add
    a new requirement, revise the `must`, or amend the `realized_by:`
    binding — and re-commit the hash so the next run is quiet.
  - **Deliberate weakening.** Author an ADR in `.spec/decisions/`
    whose `change_type` is one of `deprecates`, `weakens`,
    `narrows-scope`, or `adds-exception`. The append-only governance
    check authorizes the modal downgrade; the spec edit rides along.
  - **Should have been canonical.** A rename, reordering, or
    stylistic refactor that the canonicalizer failed to absorb. File
    a defect against `SpecLedEx.Realization.Canonicalizer`; do not
    weaken the spec to match. The `Spec-Drift: refactor` trailer
    exists for the honest case where the author confirms the change
    is behavior-preserving and the canonicalizer simply does not yet
    see it; the trailer's claim is reviewable in the diff.

  The wrong reaction is to silently re-commit the hash. That turns a
  tracked behavior change into invisible drift, and the next reviewer
  has no way to tell whether the subject still describes the system.

- `branch_guard_dangling_binding` — A binding names an MFA that no
  longer exists. Usually the symptom of a rename or removal that did
  not sweep `realized_by`.

  Almost always a bookkeeping fix: update the binding to the new
  MFA, or delete the binding if the function genuinely went away.
  `git log -S '<old name>'` finds the rename commit; if the function
  was inlined or dissolved, drop that surface-level reference and
  lean on the remaining MFAs in the closure. This finding is the
  cheapest in the catalog — there is rarely an interpretive question,
  just a stale pointer.

### Triangulation findings (coverage-side disagreement)

These say: *the spec, the code, and the tests are individually fine,
but they do not line up.* All three depend on a fresh per-test
coverage artifact from `mix spec.cover.test`; without that artifact
the whole tier reports `detector_unavailable` and these findings do
not run.

- `branch_guard_untested_realization` — A requirement's binding
  closure contains MFAs but no test's coverage records reach any of
  them. The claim is unexercised.

  **Remedy paths:**

  - **Missing test.** Write one, tag it
    `@tag spec: "<subject>.<req>"`, and re-run `mix spec.cover.test`
    to refresh the coverage artifact.
  - **Overstated binding.** An `implementation` tier closure can pull
    in helpers that the requirement does not actually demand. Narrow
    the binding — move the helpers under a different subject, or
    attach a per-requirement `realized_by:` override — so the closure
    matches the requirement's real scope.

  The finding does not pick between these; the agent decides by
  reading the requirement statement and asking whether each MFA in
  the closure is part of *that* requirement's contract.

- `branch_guard_untethered_test` — A test carries `@tag spec: "A.req"`
  but its coverage records exercise MFAs owned only by subject B. The
  tag is wrong, or the test is structured around the wrong subject.
  Default severity is `:info`, with an explicit per-test opt-out
  (`@tag spec_triangulation: :indirect`) for intentional indirect
  coverage.

  **Remedy paths:**

  - **Tag is wrong.** Retag to a B-owned requirement.
  - **Indirect coverage is intentional.** An integration-shaped test
    reaches A only through B, but A's behavior is genuinely being
    exercised end-to-end. Add `@tag spec_triangulation: :indirect`
    so the opt-out is explicit and reviewable.
  - **Test is structured wrong.** It claims to test A but never
    touches A at all. Rewrite or split it.

  The `:info` default exists because the indirect-coverage case is
  common and noisy on first adoption; the explicit opt-out keeps
  intentional indirect coverage from drifting into "everyone ignores
  triangulation."

- `branch_guard_underspecified_realization` — Coverage reaches an MFA
  owned by subject A, but the exercising test carries no `@tag spec:`
  naming an A-owned requirement. Silent execution without a claim —
  some behavior is happening that no requirement explicitly owns.

  **Remedy paths:**

  - **Missing tag.** Read the test and add `@tag spec: "A.<req>"`
    naming the A-owned requirement it actually exercises.
  - **Missing requirement.** No requirement on A fits — the spec is
    genuinely incomplete. Author a new requirement on A and have the
    test claim it.
  - **Overstated binding.** The MFA is incidental to A (a private
    helper that should not be part of A's contract). Narrow A's
    `realized_by:` so the MFA is no longer attributed to it.

  This finding is the spec corpus's pressure to *name* behavior that
  is happening anyway.

### Spec-side disagreement (within-spec consistency)

These say: *the spec corpus disagrees with itself, before any code or
test is consulted.* `mix spec.validate` surfaces them without a base
ref because they read only the current `.spec/` tree.

- `overlap/duplicate_covers` — Two scenarios in the same subject
  cover the same requirement id. Ambiguous provenance; the spec
  corpus rots.

  **Remedy paths:**

  - **Merge.** Collapse the two scenarios into one.
  - **Split the requirement.** Refactor it into two distinct ids the
    scenarios can cover separately.

  Two scenarios pointing at one requirement is sometimes legitimate
  during transition — `mix spec.validate` accepts this when the
  second scenario is marked as a replacement and the first is
  `disabled:` with a `reason:` — but the steady state is one
  requirement to many scenarios, not many scenarios to one
  requirement.

- `overlap/must_stem_collision` — Two `must` requirements in the same
  subject share the same canonicalized MUST stem. Near-duplicates
  that will drift apart.

  **Remedy paths:**

  - **Merge.** Combine the two requirements under a single id.
  - **Sharpen.** Edit one statement so the stems differ on
    substantive content — not just stop-words and modal noise that
    the canonicalizer strips.

  If two stems collide after canonicalization, the underlying claims
  are the same and one of them is doing nothing — keeping both
  invites future authors to edit one and forget the other.

- `requirement_without_test_tag` /
  `branch_guard_requirement_without_test_tag` — A `must` requirement
  covered by a `tagged_tests` verification has no `@tag spec:`
  pointing at it. The test-side claim is missing.

  **Remedy paths:**

  - **Add the tag.** Tag an existing test that exercises the
    requirement, or write a new tagged test if none does.
  - **Change verification mode.** If the requirement is verified
    another way — review-only, integration suite outside ExUnit,
    deferred to a later PR — change the verification mode away from
    `tagged_tests` so the spec advertises what it actually has.

  Leaving a `tagged_tests` verification with no claimants is a
  promise the spec cannot keep.

### Degradation (not a disagreement, a missing side)

`detector_unavailable` is structurally different from the
disagreements above. Nothing is wrong — the system is being honest
that it cannot run a check on this run because its input is absent
(no coverage artifact, no debug info, umbrella project, non-git
workspace). The tier is skipped, the finding is recorded with a
reason, and adoption can proceed without it.

Supplying the input re-enables the tier — running
`mix spec.cover.test` to produce a coverage artifact, recompiling
without `:no_debug_info`, moving off an umbrella — and the finding
goes away on its own. The graceful-degrade rule from "The five
tiers" is what surfaces this finding instead of guessing from
partial data.

### How agents work the catalog

The pattern in practice:

1. Run `mix spec.check`. Read the unresolved findings; `mix spec.next`
   highlights the first one to address.
2. For each finding, read the message and any `fix:` block, then look
   at the surrounding context — the subject spec, the affected MFAs,
   the relevant test, the recent diff. The cause matters more than
   the symptom; a drift finding can mean three different things.
3. Make the smallest change that closes the gap honestly: update the
   spec, write the test, narrow the binding, or author the ADR. Do
   not silence a finding by re-pricing it unless re-pricing is the
   considered decision.
4. Re-run `mix spec.check` to confirm the finding is gone (or that
   the severity has been deliberately downgraded).
5. Commit, with a `Spec-Drift:` trailer when the change is an
   intentional refactor / docs-only / test-only sweep that the
   trailer's domain covers. The trailer is the author's per-PR signal
   to the next reviewer.

The catalog is small on purpose. New findings should reuse existing
codes or replace one rather than expand the surface — a finding
agents do not recognize is a finding agents will work around.

## Supporting machinery

The triangle is the core. Three support systems keep it honest:

### Append-only ADR governance

`.spec/decisions/*.md` are durable cross-cutting decisions. A spec change
is rarely a pure addition — it often weakens a prior claim or replaces a
scenario. `SpecLedEx.AppendOnly` compares the prior `state.json` (at the
merge base) to the current state and emits findings for requirement
deletions, modal downgrades (`must` → `should`), scenario regressions,
polarity changes, `disabled:` without a reason, missing `change_type`,
same-PR self-authorization, and ADR deletion. Weakenings are authorized
only by ADRs whose `change_type` is one of
`deprecates | weakens | narrows-scope | adds-exception`. The finding set
is budgeted (ten codes — see `specled.decision.append_only_finding_budget`)
rather than open-ended, to keep the feedback surface legible. Every
finding message ends with a code-fenced `fix:` block agents can paste
into their edit tools.

### Severity resolution + commit trailers

Every finding gets a severity from a single resolver
(`SpecLedEx.BranchCheck.Severity.resolve/3`) with three-layer
precedence:

1. `Spec-Drift:` trailer on any commit in the PR range
   (`refactor`, `docs_only`, `test_only`, or explicit `code=severity`).
2. `.spec/config.yml` → `branch_guard.severities` and
   `guardrails.severities` (disjoint namespaces for general branch-guard
   codes vs. `append_only/*` + `overlap/*` codes).
3. Per-code default.

`:off` in config is absorbing — it beats any trailer. Unknown values fall
back to the default and log. This keeps escalation and de-escalation
explicit: a trailer on the PR, a config line in the repo, and a per-code
default in code. Nothing is implicit.

The `:info` severity exists specifically so new checks can land hot
without breaking CI. `mix spec.check` suppresses `:info` findings from
stdout by default; `--verbose` or `SPECLED_SHOW_INFO=1` unfilters them.
`.spec/state.json` always carries every finding unchanged.

### Policy-files zone classifier

`SpecLedEx.PolicyFiles` is the single place that decides what *kind* a
changed path is: `:lib | :test | :doc | :generated | :unknown`, plus
whether it participates in co-change rules. It drives both the branch
guard (which demands a spec update for lib changes) and the change-type
heuristic (which decides whether a change is `refactor`, `docs_only`,
etc.). `priv/` defaults to `:lib` (migrations and static assets carry
signal); only `priv/plts/` is `:generated`. `docs/plans/` is `:doc` but
always `:ignored` for co-change.

## The coding session, conceptually

A single session touches at most two sides of the triangle on purpose:

- **Code-only change (refactor, rename, optimization).** The
  `implementation` and/or `expanded_behavior` tier hashes change. Either
  the subject's `realized_by` stays stable (canonicalization absorbed the
  change) and `mix spec.check` passes, or a drift finding names the MFAs
  that actually shifted and the author acknowledges the change in the
  spec or in an ADR with a `narrows-scope` / `weakens` change type.
- **Behavior change.** A new requirement, new scenario, or a revised
  `must` lands in a subject spec. Tests pick up a new `@tag spec:`
  pointing at the new requirement. Code implements it. All three sides
  move together; `mix spec.next` guides the order.
- **Test-only change.** Coverage shifts but no tier hash does. The branch
  guard notices (`branch_guard_test_only_change`) and does not demand a
  spec update. Triangulation still runs, so mistagged or untethered
  tests surface here.

The verification command is aggregated: every `tagged_tests` entry across
the repo is collapsed into a single
`mix test --only spec:<id>... --include integration <files>` invocation.
One BEAM boot for the whole spec corpus, not one per subject. The
primitives that make this fast (`SpecLedEx.TaggedTests`,
`SpecLedEx.TagScanner` with AST-based `@tag spec:` extraction, the
compile tracer + xref manifest for MFA edges, per-test anonymous-ETS
coverage capture) are all engineered to keep the triangle cheap to run
on every change.

## Why this design

A few choices recur and are worth naming explicitly:

- **Honest metric names.** `execution_reach` is "N/M requirements with
  any exercised closure," not "spec coverage." A spec system that
  advertises "94% coverage" without saying what it measured is lying;
  we would rather name the fraction and let humans and agents decide
  whether it is high enough.
- **Root-cause dedup, not per-consequence flooding.** One macro provider
  change becomes one finding, not N consumer findings. One subject-B
  change becomes one subject-B drift, not a cascade across every
  subject-A that references B via the implementation tier's hash-ref
  composition.
- **Every tier ships independently useful.** `api_boundary` is useful
  even with no `implementation` tier, no coverage, and no tags.
  `implementation` adds value on top of that. Triangulation sits on top
  of everything but degrades to `detector_unavailable` without it.
  There is no forced-upgrade path.
- **Prose stays substantive.** Requirements have a `statement` that is
  long enough to be meaningful (the `prose.min_chars` / `prose.min_words`
  threshold fires `spec_requirement_too_short` as `:info`). The agent
  authoring these is not writing boilerplate; the spec file is where the
  intent lives, and a 6-word `must` requirement is almost always a
  placeholder that rots.
- **Declarative current truth.** `.spec/` is what is true *now*. Git is
  what was true before. The two are composed at review time (the
  `AppendOnly` check), not by keeping a parallel changelog inside
  `.spec/`.

## Pointers

- The triangle's three sides: `.spec/specs/realized_by.spec.md`,
  `.spec/specs/tag_scanning.spec.md`,
  `.spec/specs/coverage_capture.spec.md`.
- Triangulation itself: `.spec/specs/triangulation.spec.md`.
- The tiers: `api_boundary.spec.md`, `implementation_tier.spec.md`,
  `expanded_behavior_tier.spec.md`, `use_tier.spec.md`.
- Append-only and overlap: `append_only.spec.md`, `overlap.spec.md`.
- Severity + trailers: `severity.spec.md`, `spec_drift_trailer.spec.md`.
- The decision index: `.spec/decisions/README.md`.
