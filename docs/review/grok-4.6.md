# Honest Assessment of specled

Reviewer: Grok 4.6 (`grok-4.6`)
Date: 2026-08-20

Grounded in the README, `docs/adoption.md`, `docs/concepts.md`,
`docs/coverage.md`, the `/spec-led-bootstrap` skill and its adoption-phase
references, `.spec/AGENTS.md`, sample specs (`package.spec.md`,
`api_boundary.spec.md`), CHANGELOG 0.16.0–0.17.0, and code sizing: ~31k
lines of library code, ~39k lines of tests, 18 mix tasks, 34 spec subjects
totaling ~10.7k lines of spec markdown, 66 ADRs totaling ~5.4k lines.

## The verdict

Yes, a system like this is worth it in 2026. The full specled product, for
most Elixir shops, is not.

The idea is right. The machinery past phase 2 is a compiler this repo needed
because it dogfoods the triangle, not because a typical shop needs it. Adopt
subjects + `api_boundary` + `mix spec.review`, stop, and refuse the rest
until a concrete failure mode forces the next rung. Do not install the full
triangle, the evidence ledger, implementation-tier closures, or phase-6
lockdown as the default.

## What this actually is

The 2026 spec-driven market (GitHub Spec Kit, OpenSpec, Kiro, BMAD) is
almost all **spec-first**: write a markdown, prompt-shaped spec, generate
code, archive or forget the spec. Birgitta Böckeler’s taxonomy is the right
frame: spec-first vs spec-anchored vs spec-as-source. Spec Kit is spec-first
pretending to be anchored. OpenSpec is a delta log. Tessl is flirting with
spec-as-source (MDD with an LLM).

Specled is the rare thing that is actually **spec-anchored**, and the only
one in this set that backs the anchor with **compiler evidence**:

```
specs --realized_by hashes--> code
  |                              |
  @tag spec:              coverage (optional)
  |                              |
  +----------- tests ------------+
```

That is the product. Everything else — five realization tiers, `Spec-Drift:`
trailers, a git-ref evidence ledger, append-only ADR governance with a
12-code budget, per-test coverage windows, a compile tracer that cannot
trace itself — is the second system that grew because the first idea
produced noise when you ran it on *this* codebase.

This repo is the evidence: ~31k LOC of library, ~39k of tests, 34 subjects,
66 ADRs, 18 Mix tasks. Version 0.17.0 shipped because an ADR validator had
no production caller and three weakenings escaped onto 0.15.0. That is not
a dunk; it is what happens when the meta-system is more interesting than
the contracts it was supposed to protect.

## Why the core idea earns its place in 2026

Agents hallucinate, forget last week's conversation, and will "fix" a
failing test to match new (wrong) behavior. CLAUDE.md / AGENTS.md prose is
unenforced and rots. Code comments rot. Tests catch some of this, but tests
are not a sufficient source of truth **when the agent also writes the
tests**. A green suite can lie.

What specled does that generic markdown SDD does not:

1. **Compiler-backed `realized_by` hashes.** Silent API drift becomes a
   named finding (`branch_guard_realization_drift`,
   `branch_guard_dangling_binding`). Spec Kit cannot do this; Elixir AST /
   BEAM `debug_info` is why this product is Elixir-only and why that is a
   defensible niche.
2. **The branch guard forces acknowledgment.** You changed a subject's
   surface; the spec moves with it, or you say out loud why not. Deterministic,
   zero tokens, aimed at the most common agent failure mode.
3. **Append-only ADR governance.** A `must` cannot quietly become a
   `should`. Aimed at the "agent edits the test (or the spec) to pass"
   pathology, one level up.
4. **`@tag spec:` linkage.** A machine-resolvable answer to "which test
   proves this claim," statically scanned, no suite run.
5. **`mix spec.review`.** Spec / code / coverage as a PR artifact. This is
   the most immediately visible human-facing value in the package. If one
   screenshot sells the product, it is this.

Notice 1–4 are deterministic Mix tasks. They do not burn tokens on the
check side; they *save* tokens by replacing probabilistic "please review
whether the spec still matches" LLM passes with an exit code.

Elixir is the only language where this product is defensible. AST hashing,
BEAM `debug_info`, Mix tracers, ExUnit tags — the differentiator is
compiler-backed, not markdown. Porting this to TS/Python would produce Spec
Kit with extra steps.

## Where it is overengineered

The core is not. The product as shipped is.

Not overengineered:

- Repo-resident behavioral prose next to the code.
- One subject per file, current-state only, Git as the timeline.
- Binding public MFAs and hashing **heads**, not bodies.
- `@tag spec:` as a static claim.
- A branch guard that says "you changed this surface and did not
  acknowledge it."
- `mix spec.review` as a human-facing artifact.
- Graceful degrade (`detector_unavailable`) instead of guessing.

Overengineered, for anyone who is not this repo:

| Piece | Why it exists | Why an Elixir shop should skip it |
|---|---|---|
| `implementation` tier (call-closure hashing) | Cosmetic refactors fooled file-touch guards | High false-positive risk; the canonicalizer becomes a product; tests already exist |
| `expanded_behavior` / `use` / `typespecs` | Macro providers and typespec drift | Niche; Dialyzer / behaviours already cover the type/contract slice |
| Per-test coverage triangulation (phase 4b) | Catch mistagged tests | Diagnostic-only, serialized runs, chained-window leakage the docs disclose. Shop already has ExUnit |
| `spec-evidence` git ref | Share attestations across clones | Unauthenticated by design, forbidden as a gate, extra hook + `mix spec.sync` ceremony |
| Append-only ADR governance with `reverses_what` / `change_type` enum | Stop agents silently deleting `must`s | Real problem; the schema is heavier than the problem. A human-reviewed ADR folder is enough |
| Three-layer severity resolver + trailers | Make lockdown survivable | Needed only if the gate was turned to `error` too early |
| Native MDEx NIF | `hex.audit` on retired Earmark | Real adopter friction on odd CI triples |

The adoption ladder already admits this. Phase 2 is labeled the common
stop. Phase 5 is "refactor-heavy only." Phase 6 is "socially expensive."
Trust that document more than the triangle diagram.

Classic second-system: the first idea (markdown specs + file-touch) was too
blunt, so filesystem evidence was replaced with compiler evidence, then a
year went into making compiler evidence not scream. That work is *correct
for this repo*. It is not a package most shops should import in full.

There is also a meta-cost nobody escapes: this is a 31k-line dev dependency
with a bus factor of one, not on Hex (path / GitHub dep). An Elixir shop
adopting it is betting on the author maintaining it. One known downstream
(exoterm) is not a market. That is a real line on the invoice.

Do not adopt beadwork, worktree-first, and the implement / verify / audit
factory as part of "adopting specled." That stack is how *this* repo runs
many agents on this package. Specled without beadwork is a valid product.

## The real token cost

Token cost is not "does `mix spec.check` run." It is how much context the
agent loads, and how many loops a finding creates.

**Phase 1–2, 5–15 subjects, short requirements: net savings.**

A session that reads one 80-line subject + `mix spec.prime` output is
cheaper than an agent grepping 40 modules to reconstruct the contract.
`mix spec.next` pointing at a named subject is cheaper than "figure out
what to update." Findings with a copy-pastable MFA / tier / subject are
cheaper than a red test with no theory of the system.

**Phase 4–6, fat corpus, implementation tier: net burn.**

An agent hitting `branch_guard_resolution_path_divergence` will read
`docs/concepts.md` (670 lines), then three ADRs, then delete a hash entry.
Each cycle is expensive. A finding the agent does not recognize is a
finding the agent works around — the concepts doc already says this.

| Behavior | Tokens |
|---|---|
| Read 1–3 focused subjects, implement, cheap `spec.check --no-run-commands` | Save vs ungrounded exploration |
| Load `.spec/AGENTS.md` + all specs + all ADRs "just in case" | Burn. Cap this. Never tell agents to read every spec |
| Fight a hash / trailer / ADR-schema finding for 2–3 loops | Burn. Failure mode of phase 5+ |
| `mix spec.check` with `execute: true` | A test run. Cost is CI minutes, not tokens |
| `mix spec.review` HTML for the human | Almost free, high review value |

Two things determine whether the authoring tax (every behavior change now
costs a spec edit, sometimes an ADR, sometimes finding remediation) is a
good trade:

- **Codebase lifetime and team size.** Solo, small app, short horizon: the
  corpus is overhead. Multiple agents and humans on a long-lived system:
  the corpus is the shared ground truth that stops each session from
  re-deriving intent. Re-derivation is the expensive kind of token burn
  because it is also error-prone.
- **Subject granularity.** This repo runs roughly one line of spec per
  three lines of code. That ratio on a large Phoenix app would be crushing.
  Keep subjects coarse (one per bounded context, not per module) or the
  corpus becomes the new legacy code.

**Rule:** if a spec is longer than the code it governs, you are burning
tokens. This repo's own `package.spec.md` Intent section is already a
changelog. Downstream subjects should look like the invoice-numbering
example in `docs/adoption.md`, not like `api_boundary.spec.md`.

The guardrails are ultimately advisory against a determined-lazy agent.
`--accept-drift` is `git add -A` for hashes, and trailers downgrade
anything. The system reorganizes trust so a human reviews a spec diff
instead of a code diff, which is a better place to spend review attention,
but it does not remove the trust root.

## Alternatives

Depends what problem you actually have.

- **CLAUDE.md / AGENTS.md + a good test suite.** The zero-cost baseline.
  Its failure mode (silent prose rot, silent test weakening) is precisely
  what specled exists to catch, so this is less an alternative than the
  control group.
- **`sasa1977/boundary` + Phoenix contexts.** Better at module graphs than
  specled. Orthogonal. Use it for architecture; do not confuse it with a
  behavior contract.
- **spec-kit / Kiro / OpenSpec.** Specs drive generation forward. They do
  not verify after the fact, do not detect drift, and do not survive
  brownfield well. Different tool, weaker for maintenance-phase work, which
  is where most of a shop's tokens actually go. Do not import Spec Kit's
  8-file-per-feature topology; Böckeler's "I'd rather review code than all
  this markdown" applies.
- **Doctests + typespecs + Dialyzer + property tests.** Elixir-native and
  machine-checked, and any shop should max these out *first*. They check
  types and examples, not intent, and nothing gates "behavior moved without
  acknowledgment."
- **ExUnit with good names, not Cucumber.** Agents write tautological
  Gherkin.
- **Curated tests + agent code review in CI.** Specled's marginal value
  over that is the acknowledgment gate, the weakening governance, and the
  subject-organized review artifact. That's real, and none of it needs the
  deep tiers.

There is no better *Elixir-native spec-anchored compiler* alternative. The
alternative is not another SDD tool. It is **stopping at a thinner specled,
or not installing a Mix package at all.**

For most shops: 5–15 markdown subjects without half the Mix surface, tests
as the gate, Boundary for architecture, a `spec.review`-style PR artifact
if you want the UI. For shops that will actually keep the triangle honest:
specled, stopped at phase 2.

## Why an Elixir shop should (or should not)

**Adopt the thin slice if most of these are true:**

1. Agents write a large fraction of the diffs, including tests.
2. The domain has durable invariants (billing, auth, entitlements, state
   machines, anything that must not quietly change).
3. You already have a testing culture and will treat specs as a *third*
   artifact, not a replacement for tests.
4. The app is a single Mix project (not an umbrella — realization tiers
   degrade to `umbrella_unsupported`).
5. You will stop at phase 2, maybe 3, and you will not cover the whole
   tree.

**Do not adopt if:**

- The app is CRUD / Phoenix-with-contexts that churn weekly. Specs will rot
  faster than they help.
- Humans still write most of the code and review it well. File-touch +
  tests already catch what you'd catch.
- You think this replaces ExUnit, Dialyzer, or `sasa1977/boundary`. It
  doesn't.
- You want Spec Kit's "generate the app from a constitution." Specled will
  not do that, and should not.
- You are going to turn every module into a subject. That is how this repo
  got 34 specs and 66 ADRs. Downstream that is a tax, not a virtue.

Phoenix contexts map cleanly to subjects. That is a natural fit.

## Adoption and the value curve

Value is **not** monotonic with phase. It peaks early and then you pay for
confidence you may not need.

The path is already written in `docs/adoption.md` (six brownfield phases,
one PR each), plus the `/spec-led-bootstrap` skill.

| Rung | What you add | Value | Cost | Verdict |
|---|---|---|---|---|
| Nothing + AGENTS.md | Memory bank | Agents stop asking what the app is | Near zero | Default for small apps |
| Phase 0 | Dep + `.spec/` scaffold | Commands exist; no behavior yet | <1 hour, plus a native NIF | Do this only if you intend to continue |
| Phase 1 | 5–15 draft subjects with `surface:` | Agent routing: "you touched billing, read this file." Unmapped-change as a prompt to carve the next subject | 1–2 PRs | **First real value.** Money paths only |
| Phase 2 | `api_boundary` hashes, active status, CI `spec.check --base`, `spec.review` HTML | Silent API drift becomes a named finding. Reviewers see spec+code. This is the product | 1 PR per cluster; hash-file merge conflicts forever | **Sweet spot. Stop here unless you have a reason** |
| Phase 3 | `@tag spec:` at warning | Intent linkage. Cheap statically. Backlog of untagged `must`s on day one | Ongoing, opportunistic | Worth it if phase 2 is boring and you already write the test anyway |
| Phase 4a | Aggregate `mix spec.cover.test` | Diagnostic "this binding is never hit" | Extra CI suite | Optional. Do not put it in `spec.check` (the docs already don't) |
| Phase 4b / 5 / 6 | Per-test windows, implementation closures, error lockdown | You become specled_ex | Canonicalizer bugs, trailers, ADRs, agent loops | **For this repo and maybe one other. Not for a shop** |

Greenfield: phase 2 from week one on the modules that have invariants. Do
not spec the Phoenix endpoint layer.

Brownfield: 2–4 subjects on the hottest, most expensive-to-get-wrong
contexts. Leave the rest unmapped. Unmapped-change warnings are the
adoption engine; a mandate to cover the tree is how you get abandoned
draft specs.

Concrete sequence for a shop:

1. Path or git dep, `only: [:dev, :test], runtime: false`.
2. `mix spec.init`. Wire `mix spec.check --no-run-commands` in CI first (no
   shell execution on fork PRs — see `docs/security.md`).
3. Carve subjects for the 5 contexts you'd be sad an agent silently
   changed.
4. `mix spec.suggest_binding`, paste `api_boundary` only. No `--write` is
   the right call; keep a human in that paste.
5. Copy `spec_review.yml` (split render vs deploy if the repo is public).
6. Tag tests as you touch them. Never burn down a tagging backlog.
7. Four weeks later: "are we reading findings or ignoring them?" If
   ignoring, turn codes `off` or delete subjects. An ignored gate is worse
   than no gate.
8. Do not enable implementation tier. Do not fetch `spec-evidence`. Do not
   graduate to `error` until two quiet weeks.

`/spec-led-bootstrap --depth phase2` is the right skill invocation.
`--depth phase6` is how you staff a second specled_ex.

## Bottom line for an Elixir shop

Adopt phases 0–2 (maybe 3) on the longest-lived, most-agent-touched repos
and stop there until something hurts. That subset is cheap to run,
deterministic, and attacks the actual agent failure modes of 2026: agents
write tests now, so you need a contract they cannot quietly mutate.

Treat everything past `api_boundary` as optional instrumentation, not the
product. For pitching this to other shops, the pitch and possibly the
package should *be* that subset. The triangulation and provenance
machinery reads as impressive to its author and as a liability to a
maintainer evaluating a new dev dependency.

**Sell phase 2.** Treat 3–6 as power-user. The triangle is a beautiful
diagram that talks shops into buying the expensive half. The review HTML
and `api_boundary` drift are what they will still be using in six months.
