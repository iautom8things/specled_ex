# Honest Assessment of specled

Reviewer: Qwen 3.8 (`qwen/qwen3.8-2.4t-a95b`)
Date: 2026-08-20

Grounded in the lib tree, `.spec/specs/` and `.spec/decisions/`, a sample spec
(`append_only.spec.md`), `docs/adoption.md`, the README, and a live run of
`mix spec.prime --base HEAD`. Code sizing: ~31.4k lines of library, ~38.8k
lines of tests, 18 mix tasks, 236 commits over ~5.5 months. The dogfooding
repo carries 34 subjects, 459 requirements, 65 ADRs, ~10.7k lines of spec
markdown, ~5.4k lines of ADR prose.

## The verdict

Real product, right problem, oversized surface. The core — specs as
declarative current truth, mechanically cross-checked against code and tests —
is sharp and timely. The apparatus around it (five realization tiers, evidence
store, per-test coverage attribution, HTML review renderer) is research-grade
superstructure on a workflow tool. An Elixir shop should adopt the cheap core
and treat the depth as opt-in instrumentation.

## Why the core earns its place in the agent era

The agent era strengthens the case rather than weakening it. Agents multiply
the failure class specled detects: silent behavioral drift. A refactor that
nudges a contract, a cleanup that deletes an edge case, a requirement quietly
downgraded. Tests only catch that if a test exists *and nobody weakens it*.
Two of specled's mechanisms attack exactly this, and nothing else in the
Elixir ecosystem does:

1. **The branch guard forces reconciliation.** "You changed files in a
   subject's surface but didn't touch the spec" is a deterministic, diff-time
   check. It catches the most common agent failure mode with zero tokens and
   zero judgment calls.
2. **Append-only governance gates weakening itself.** A `must` can't quietly
   become a `should`, and a requirement can't vanish without an accepted ADR
   that names it. This targets the "agent edits the test to pass" pathology
   one level up — it makes weakening the safety net a reviewable event.
3. **`@tag spec:` linkage** gives a fresh-context agent (or verifier) a
   machine-resolvable answer to "which test proves this requirement."

All three are deterministic mix tasks producing exit codes, which is the right
shape for CI and for agents: mechanical checks replace probabilistic
"please review whether intent survived" LLM passes.

## Where it is overengineered

There is a ~20% core delivering ~80% of the value: spec files, requirement
IDs, tag scanning, branch guard, ADR authorization. Everything past that is
where the tool serves its own ambition more than its adopters:

- **Five realization tiers** (`api_boundary` → `implementation` →
  `expanded_behavior` → `use` → `typespecs`) with BEAM-first binding
  resolution, closure expansion, and hash-store provenance. Most product
  teams will never feel the problems tiers 2-5 solve.
- **Per-test coverage attribution** — serialized runs, boundary hooks,
  chained-window exactness caveats — for a read-only diagnostic that
  `spec.check` never gates on. High wiring cost, no gate value.
- **18 mix tasks.** Too much surface for a team to hold in its head; a
  junior dev faces a real orientation cost before the tool starts paying.

A tell: three successive `append_only_finding_budget` ADRs — the system
repeatedly had to impose budgets on its own finding growth. And the repo's own
rules carry merge-conflict liturgy for `realization_hashes.json` ("take the
labeled side or you silently revert to legacy semantics"). When the author
needs written operating procedure to run their own tool safely, adopters will
hit those edges harder.

## Adopt / don't adopt, for an Elixir shop

**Adopt because:** it's Elixir-native (mix tasks, ExUnit tags,
`runtime: false`, one precompiled native dep used only for the review
artifact, no service to run); degrade paths make brownfield safe — missing
detectors produce findings, not build failures; the gate is cheap and runs
identically locally and in CI; and it externalizes intent into files that
survive agent session boundaries, which is the memory problem every agent
shop has.

**Don't adopt because:** spec authoring is a real ongoing tax — a behavior
change means spec + code + test, sometimes an ADR. Teams without existing
spec discipline will resent it and reach for the escape hatches (the
`Spec-Drift: …=info` trailer exists precisely to clear findings by
proclamation). It is also ~5 months old with one center of gravity — adopting
it is adopting a bet on continued maintenance, and it is not on Hex. For a
fast-moving product codebase this friction gets removed within a quarter;
that is the realistic failure mode of process tooling.

**The two conditions under which it is worth it:**

1. The contracts are durable and worth writing down — billing, ledgers,
   permissions, protocol boundaries, regulatory logic. Not a product still
   being searched on.
2. Agents do a meaningful share of the work, so human review of every diff
   is the bottleneck.

If either fails, the ceremony costs more than it catches.

## Alternatives

- **CLAUDE.md/AGENTS.md + strong ExUnit suite + property tests + strict CI.**
  80% of the value at 5% of the cost for most shops, and the honest default.
  Its failure mode — silent prose rot, silent test weakening — is precisely
  what specled exists to catch, so it is less an alternative than the control
  group.
- **Doctests + typespecs + Dialyzer + StreamData.** Elixir-native and
  machine-checked; max these out first regardless. They check types and
  examples, not intent, and nothing there gates "behavior moved without
  acknowledgment."
- **Spec-driven generation tools (spec-kit / Kiro style).** Specs drive
  generation forward; they don't verify after the fact, don't detect drift,
  and don't survive brownfield. Weaker exactly where a shop spends most of
  its maintenance tokens.

Specled's marginal value over the baseline is the acknowledgment gate, the
weakening governance, and subject-organized review. That's real, and none of
it needs the deep tiers.

## Token economics

Measured, not vibes:

| Source | Size | Tokens |
|---|---|---|
| `mix spec.prime --base HEAD` output | ~40 lines | ~600 |
| Always-loaded `.claude/rules/` | 219 lines | ~2.5k |
| One subject spec (mean ~315 lines) | ~10.7k / 34 | ~3-4k |

Direct context cost is trivial: 5-10k tokens per session against a 200k
window. The real burn is indirect — the reconciliation loop makes
contract-touching sessions longer: update spec, re-run `spec.next`, clear
findings, maybe write an ADR. Call it +20-40% session length for contract
changes, ~0% otherwise (`spec.next` says "no contract update needed" and you
move on). That is the correct trade when the contract matters and waste when
it doesn't — which is exactly why the tiering matters.

One caveat: the guardrails are advisory against a determined-lazy agent.
`--accept-drift` is `git add -A` for hashes, and trailers downgrade anything.
Specled reorganizes trust so a human reviews a spec diff instead of a code
diff — a genuinely better place to spend review attention — but it does not
remove the trust root.

## Adoption path and the value curve

Mechanics (from `docs/adoption.md`): add the dep with `runtime: false` →
`mix spec.init` → enable `test_tags` at `enforcement: warning`, graduate to
`error` → phase gates in over several PRs (brownfield) → `spec.check` in CI.

The value ladder, with my ROI read:

| Tier | What you turn on | Cost | Verdict |
|---|---|---|---|
| 1 | `@tag spec:` scanning, warning → error | Low | Highest value/cost ratio. Every `must` provably has a test, statically. Adopt. |
| 2 | Branch guard (surface mapping, missing-subject-update, unmapped-change) | Low | The anti-drift core. Agents can't touch a surface without reconciling the spec. Adopt. |
| 3 | ADR authorization + append-only governance | Low | Compounds the longer the corpus lives. Adopt. |
| 4 | `realized_by: api_boundary` + hash drift | Medium | Real refactor early-warning, real upkeep. Try on critical subjects only. |
| 5 | Deeper realization tiers, evidence store, per-test triangulation, review artifact | High | Diminishing returns; diagnostics, not gating. Skip until a specific pain appears. |

Value tiers do track adoption tiers, and the curve bends hard after
`api_boundary`. Tiers 1-3 are maybe a fifth of the machinery and most of the
value.

## Bottom line

If I ran an Elixir shop with durable contracts and heavy agent use, I'd adopt
tiers 1-3 without hesitation on the longest-lived, most-agent-touched repos,
and stop there until something hurts. For a young product codebase, I'd skip
it, buy strong tests + CI instead, and revisit when the first agent refactor
silently breaks a contract that was everyone's tribal knowledge. And if this
is being pitched to other shops: the pitch, and possibly the package, should
*be* the subset. The deep machinery reads as impressive to its author and as
a liability to a maintainer evaluating a new dev dependency.
