# SpecLedEx product assessment

- Model: GPT-5
- Reviewed: 2026-08-20

## Recommendation

Do not roll out the full system across an Elixir shop today.

A narrower version is worth adopting:

- Repo-resident descriptions of important business behavior
- Stable requirement IDs
- Focused ExUnit tests linked to those requirements
- A command that tells an agent which contract its change affects
- ADRs for genuinely durable decisions

That is the useful core of SpecLedEx.

The complete package is overengineered for most shops. Implementation hashing,
five realization tiers, compile tracing, per-test coverage attribution, evidence
refs, append-only governance, HTML review generation, and native Markdown
rendering combine several experimental ideas into one workflow. They create
more maintenance machinery than demonstrated product value.

The recommended starting point is a one-domain pilot using the equivalent of
adoption phases 0, 1, and 3. Skip implementation hashes, per-test coverage, and
evidence storage.

## Evidence from this repository

This is serious engineering, not vaporware:

- Both the structural and full spec gates passed.
- Current CI is green on Elixir 1.18 with OTP 26 and Elixir 1.19 with OTP 28.
- `mix spec.prime` produced a useful 229-word orientation report in 1.89
  seconds.
- `mix spec.next` took 1.16 seconds.
- The structural gate took 3.76 seconds.
- `mix spec.review` rendered a change-oriented artifact in 7.16 seconds.

The full gate took 200.5 seconds on a clean, warm checkout. This repository has
23 explicit command verifications, so a disciplined adopter can do much better
by using one aggregated tagged-test run. Three minutes for a no-change gate is
still a warning.

The dogfood corpus is also large:

| Artifact | Size |
|---|---:|
| Library code | 31,399 lines |
| Subject specs | 10,723 lines, 504 KB |
| ADRs | 5,381 lines, 266 KB |
| Tests | 38,803 lines |
| Current model | 34 subjects, 65 decisions, 459 requirements |

A governance product will naturally have an unusually large spec corpus. Even
with that caveat, this is a lot of second-order material to maintain.

As of the review date, the repository looks like a pre-product project:

- It has an internal `0.17.0` version, but no GitHub release or version tag.
- It is not packaged for Hex. [`mix.exs` says "if this project is ever
  published to Hex."](../../mix.exs#L4-L8)
- The public repository has no license.
- There is no external adoption signal yet.
- Realization tiers do not support umbrella roots. They degrade to
  `umbrella_unsupported`, as described in the [adoption
  guide](../adoption.md#decision-points).

This does not make the project bad. It means an external shop should not treat
it as a stable dependency yet.

## What the triangle proves

The docs call a closed triangle "triangulated proof." That overstates what it
establishes. See the [triangle description](../concepts.md#the-triangle).

The three sides prove traceability:

- Someone said a requirement maps to an MFA.
- Someone tagged a test with the requirement ID.
- Coverage observed that an MFA executed.

They do not prove that the assertion tests the requirement, that the
requirement is correct, or that the test would fail when the behavior regresses.

The open backlog demonstrates this:

- [`tagged_tests` targets can point at an unrelated
  file](https://github.com/iautom8things/specled_ex/blob/beadwork/issues/specled_-b75.json).
- [Blanket module tags can keep a requirement "covered" after its actual tests
  are deleted](https://github.com/iautom8things/specled_ex/blob/beadwork/issues/specled_-r2i.json).
- [Generated tests cannot always reach executed
  strength](https://github.com/iautom8things/specled_ex/blob/beadwork/issues/specled_-wv0.json).
- [Implementation-hash determinism still needs a cross-compile
  audit](https://github.com/iautom8things/specled_ex/blob/beadwork/issues/specled_-l05.json).

The system should be positioned as a contract drift detector and review router,
not a proof system. That is still useful and is a more defensible claim.

## When an Elixir shop should adopt it

SpecLedEx becomes valuable when several of these are true:

- Agents and humans frequently hand work between sessions.
- Important behavior cannot be inferred from code alone.
- Silent weakening of requirements is expensive.
- Several contexts or applications participate in one workflow.
- Reviewers need to answer, "Which contract changed, and which test claims to
  prove it?"
- The shop can assign human ownership to the written requirements.

Elixir is a decent fit. ExUnit tags are native, Mix tasks make the workflow easy
to distribute, compiler metadata is available, and property tests can express
real invariants well.

Agents strengthen the case for externalized intent. Better agents can read
code, but code still cannot tell them why a strange restriction exists or which
apparently reasonable behavior is forbidden.

Agents weaken the case for authored implementation maps. Modern agents are
good at finding modules, callers, tests, and types. Paying humans or agents to
maintain `surface:` lists and MFA inventories often duplicates information they
can discover.

## When to skip it

Do not adopt the full system for:

- A small shop with good tests and short review cycles
- Ordinary CRUD applications
- Products whose requirements change weekly
- Teams that already neglect documentation
- Umbrella projects expecting realization-tier support
- Repositories where the spec mostly restates function names and
  implementation details
- Teams unwilling to investigate false positives instead of adding escape
  trailers

The dangerous failure mode is ceremonial compliance. Agents become excellent
at updating the spec, hash baseline, tag, and ADR together. Every gate turns
green, but nobody gains information.

## Token and execution cost

The system can burn tokens unless context loading stays tightly scoped.

The command output itself is cheap. `spec.prime` produced about 229 words. The
generated skill is around 1,639 words, which is a modest recurring context
cost.

The shipped `.spec/AGENTS.md` is the bigger problem. It tells agents to [read
all current subject specs before
editing](../../priv/spec_init/AGENTS.md.eex#L7-L11). In this repository that
means loading 504 KB of specs, roughly six figures of tokens depending on the
tokenizer. That instruction should tell agents to read only the subjects named
by `spec.next`, the current task, or an explicit `Advances:` field.

The indirect token cost is larger:

- More files to inspect
- More artifacts to update
- More gate failures to triage
- More agent steps spent proving bookkeeping consistency
- Potential duplication between the task, spec, test, ADR, and PR

Research is mixed, which is why each adopter should measure this. One 2026
study of 124 PRs found `AGENTS.md` reduced output tokens by 16.6 percent and
median runtime by 28.6 percent. A separate benchmark found context files
increased cost by 20 to 23 percent without a significant success-rate
improvement, though human-written files did better than generated ones. A later
study found carefully tested and refined guidance raised solve rate from 25.5
percent to 33 percent.

Sources:

- [On the Impact of AGENTS.md Files on the Efficiency of AI Coding
  Agents](https://arxiv.org/abs/2601.20404)
- [Evaluating AGENTS.md: Are Repository-Level Context Files Helpful for Coding
  Agents?](https://arxiv.org/abs/2602.11988)
- [Probe-and-Refine Tuning of Repository Guidance for Coding
  Agents](https://arxiv.org/abs/2606.20512)

Generic and redundant context burns tokens. Small, human-owned guidance that
contains facts absent from the code can pay for itself.

## A better default

For most Elixir shops, use a thin contract stack:

1. A concise `AGENTS.md` containing setup, verification commands,
   architectural boundaries, and non-obvious traps. The format is supported
   across many coding agents and used by more than 60,000 public projects. See
   [AGENTS.md](https://agents.md/).
2. Small `docs/contracts/<domain>.md` files for business invariants that cannot
   be recovered from code.
3. Task-local acceptance criteria in the ticket or PR.
4. ExUnit examples and StreamData properties as the executable truth. Property
   tests are especially appropriate for monotonicity, idempotency,
   authorization, serialization, and state-machine invariants. See
   [ExUnitProperties](https://stream-data.hexdocs.pm/ExUnitProperties.html).
5. ADRs only for decisions that will constrain future changes.
6. One small linter checking that critical requirement IDs resolve to focused
   tests.

If an existing planning workflow is preferred, OpenSpec is the closest
lightweight alternative. It separates current-truth specs from proposed
changes and supports more than 30 assistants. It does not attempt SpecLedEx's
runtime traceability. See [OpenSpec](https://github.com/Fission-AI/OpenSpec).

GitHub Spec Kit is more established and more process-heavy. Kiro has a polished
requirements, design, and tasks workflow but ties the workflow to its
environment. See [Spec Kit](https://github.github.com/spec-kit/) and [Kiro
specs](https://kiro.dev/docs/specs/).

None replaces SpecLedEx exactly. Planning, agent guidance, behavioral
verification, and architectural governance do not necessarily need one unified
system.

## Adoption tiers

| Tier | What to adopt | Likely value | Verdict |
|---|---|---|---|
| 0 | `AGENTS.md`, normal CI, strong ExUnit tests | High for almost every shop | Adopt |
| 1 | A few current-truth domain specs plus `spec.prime` and `spec.next` | Better agent handoffs and change routing | Good pilot |
| 2 | Stable requirement IDs and focused `@tag spec:` annotations, warning only | Useful traceability in critical domains | Recommended initial ceiling |
| 3 | CI enforcement for selected contracts, limited `api_boundary`, HTML review | Useful for high-risk or multi-agent work | Adopt after measured wins |
| 4 | Implementation hashes, compiler tracer, aggregate coverage triangle | More disagreement detection with more noise and maintenance | Experimental |
| 5 | Per-test attribution, append-only governance, evidence refs, full-repo coverage | Compliance-grade ceremony without demonstrated assurance | Niche |

## Pilot plan

1. Pick one bounded domain with expensive mistakes, such as authorization,
   billing, provisioning, or an external protocol.
2. Pin an exact commit. Do not depend on a floating branch.
3. Run `mix spec.init`, then fix the generated instructions so agents read only
   impacted subjects.
4. Use `mix spec.status --no-run-commands` for inspection. The current scaffold
   incorrectly calls plain `spec.status` read-only, while the implementation
   executes repository shell by default. Compare the [scaffolded
   claim](../../priv/spec_init/agents/skills/spec-led-development/SKILL.md.eex#L117-L122)
   with the [task behavior](../../lib/mix/tasks/spec.status.ex#L9-L15).
5. Author three to five subjects. Keep each one small and limited to facts that
   cannot be inferred from code.
6. Tag individual tests. Avoid broad `@moduletag spec:` lists.
7. Keep enforcement at warning for a month. Skip implementation hashes and
   coverage triangulation.
8. Measure agent tokens, agent steps, gate time, false positives, escaped
   defects, and reviewer time.
9. Graduate one finding code at a time only when it has caught real mistakes
   with acceptable noise.
10. Stop expanding if the system mostly catches missing bookkeeping.

## Product direction

The strongest product is smaller than the current one:

- Keep `prime`, `next`, subject schemas, focused test tags, and the review
  artifact.
- Make every inspection command non-executing by default.
- Change generated instructions to load only impacted subjects.
- Call the output traceability evidence, not proof.
- Move implementation hashes and per-test coverage behind an explicit
  experimental flag.
- Support umbrella adoption before pitching the package broadly to Elixir
  shops.
- Publish a licensed Hex package with real releases.
- Prove value in two external repositories using measured defect catches,
  token consumption, false-positive rates, and gate time.

The bold move is subtraction. A small contract reconciler could be genuinely
useful in an agent-heavy Elixir shop. The current all-in system asks adopters to
trust too many novel mechanisms before the core value has been proven.
