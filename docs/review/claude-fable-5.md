# Honest Assessment of specled

Reviewer: Claude Fable 5 (`claude-fable-5`)
Date: 2026-08-20

Grounded in the README, `docs/adoption.md`, `docs/concepts.md`, a sample spec
(`branch_guard.spec.md`), and code sizing: ~31k lines of library code, ~39k
lines of tests, 18 mix tasks, 33+ spec subjects totaling ~10.7k lines of spec
markdown in this repo.

## The verdict

The core idea is right and the timing is right. The execution is about 70%
right, with a heavy tail that I'd call overengineered relative to what most
adopters will ever run. The good news is the design already knows this:
adoption is tiered, and the cheap tiers hold most of the value.

## Why the core idea earns its place in 2026

The problem specled attacks is real and getting worse, not better, as agents
improve. Agents don't drift because they're dumb; they drift because intent
lives nowhere durable. CLAUDE.md prose is unenforced and rots. Tests encode
behavior but not intent hierarchy, and agents demonstrably weaken tests to get
green. The three things specled does that nothing else in the Elixir ecosystem
does:

1. **The branch guard forces acknowledgment.** "You changed code a subject
   owns; either the spec moves with it or you say out loud why not." That's a
   deterministic gate, zero tokens, and it targets the single most common
   agent failure mode.
2. **Append-only ADR governance stops silent weakening.** A `must` can't
   quietly become a `should`. This is aimed directly at the "agent edits the
   test to pass" pathology, one level up.
3. **`@tag spec:` linkage** gives an agent a machine-resolvable answer to
   "which test proves this claim," which is exactly the question a
   fresh-context verifier asks first.

Notice all three are deterministic mix tasks. They don't burn tokens; they
*save* tokens by replacing probabilistic "please review whether the spec still
matches" LLM passes with an exit code. The token-burn worry points the wrong
direction for the check side.

## Where it is overengineered

The realization machinery past `api_boundary` is where the tool serves its own
ambition more than its users. Five hash tiers, canonicalized AST hashing,
Cargo-style hash-ref composition, resolution-path provenance with
beam-vs-source comparability rules, silent-seed passes, a run-scoped
divergence seed gate. The concepts doc needs 667 lines to explain the finding
catalog, and the repo's own CLAUDE.md carries merge-conflict liturgy for
`realization_hashes.json` ("take the labeled side or you silently revert to
legacy semantics"). When the author needs written rules to safely operate
their own tool, adopters will hit those edges harder. The "`:off` suppresses
the report but not the refresh block" trap is documented, which is honest, but
a system that can freeze state with nothing on screen explaining why is a
system carrying too many interacting mechanisms.

Per-test coverage attribution (Phase 4b) is the weakest ROI in the whole
package. Serialized runs, boundary hooks in every case template, exactness
caveats about chained windows and process leakage. The docs themselves say
most teams should skip it, and I'd go further: consider cutting it from the
product and letting `mix spec.triangle` on aggregate coverage be the ceiling.

The evidence store and `spec.sync` are heavy for what they deliver, given that
evidence is explicitly forbidden as a merge-gate input. An attestation that
can't gate anything is mostly ceremony.

There's also the meta-cost nobody escapes: this is a 31k-line dev dependency
with a bus factor of one, not on Hex. An Elixir shop adopting it is betting on
the author maintaining it. That's not a knock on the code, it's a real line on
the invoice.

## The real token cost

The tokens go into authoring and maintaining the spec corpus, not the checks.
Every behavior change now costs a spec edit, sometimes an ADR, sometimes
finding remediation. Call it 10-25% more agent output per behavior-changing
PR. Two things determine whether that's a good trade:

- **Codebase lifetime and team size.** Solo dev, small app, short horizon:
  the corpus is overhead you'll resent. Multiple agents and humans on a
  long-lived system: the corpus is exactly the shared ground truth that stops
  each session from re-deriving intent, and re-derivation is the expensive
  kind of token burn because it's also error-prone.
- **Subject granularity discipline.** This repo runs roughly one line of spec
  per three lines of code. That ratio on a large Phoenix app would be
  crushing. Adopters must keep subjects coarse (one per bounded context, not
  per module) or the corpus becomes the new legacy code.

One more honest caveat: the guardrails are ultimately advisory against a
determined-lazy agent. `--accept-drift` is `git add -A` for hashes, and
trailers downgrade anything. The system reorganizes trust so a human reviews a
spec diff instead of a code diff, which is a genuinely better place to spend
review attention, but it doesn't remove the trust root.

## Alternatives

- **CLAUDE.md + rules + a good test suite.** The zero-cost baseline. Its
  failure mode (silent prose rot, silent test weakening) is precisely what
  specled exists to catch, so this is less an alternative than the control
  group.
- **spec-kit / Kiro-style spec-driven development.** Specs drive generation
  forward. They don't verify after the fact, don't detect drift, and don't
  survive brownfield. Different tool, weaker for maintenance-phase work,
  which is where most of a shop's tokens actually go.
- **Doctests + typespecs + Dialyzer + property tests.** Elixir-native and
  machine-checked, and any shop should max these out *first*. But they check
  types and examples, not intent, and nothing gates "behavior moved without
  acknowledgment."

The honest competitive comparison is "curated tests + agent code review in
CI." Specled's marginal value over that is the acknowledgment gate, the
weakening governance, and the subject-organized review artifact. That's real,
and none of it needs the deep tiers.

## Adoption and the value curve

The path is already written in `docs/adoption.md` (six brownfield phases, one
PR each), plus the `/spec-led-bootstrap` skill. My ROI ranking differs a
little from the phase order:

| Phase | Cost | My read |
|---|---|---|
| 0-1: subjects + `surface:` | Low | High value. An enforced, structured CLAUDE.md. |
| 3: test tags | Low | Best feature in the package. Pull it ahead of Phase 2. |
| 2: `api_boundary` | Low | Good. Cheap hashes, real drift signal. |
| 4a: aggregate coverage | Medium | Fine as a diagnostic. Take or leave. |
| 4b: per-test | High | Skip. Probably forever. |
| 5: `implementation` tier | High | Skip unless churn is refactor-heavy, as the docs already say. |

So yes, value tiers track adoption tiers, and the curve bends hard after
`api_boundary`. Phases 0-3 are maybe a fifth of the codebase and, I'd
estimate, 80% of the value.

## Bottom line for an Elixir shop

Adopt phases 0-3 on the longest-lived, most-agent-touched repos and stop
there until something hurts. That subset is cheap to run, deterministic, and
attacks the actual agent failure modes of 2026. Treat everything past it as
optional instrumentation, not the product. And for pitching this to other
shops, the pitch and possibly the package should *be* that subset; the
triangulation and provenance machinery reads as impressive to its author and
as a liability to a maintainer evaluating a new dev dependency.
