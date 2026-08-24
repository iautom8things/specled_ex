# SpecLedEx product review — z-ai/glm-5.3

Reviewed 2026-08-20. Questions asked: is a system like this worth adding in the
agent era, is it overengineered, should an Elixir shop adopt it, what is the
better alternative, does it just burn tokens, how do you adopt it, and do the
tiers of adoption align with tiers of value.

All numbers below come from the repo itself, not the pitch.

## The short verdict

The core idea is right for this moment, and the enforcement half of it is
durable value that better models won't erase. The upper tiers are overbuilt for
most adopters, and this repo's dogfood is quietly the best evidence for both
claims. For an agent-heavy Elixir shop: worth adopting at the core tier. Not
worth adopting whole.

## Is it worth it in the agent era

Yes, and more than it would have been in 2019. BDD failed for a structural
reason. The promised readers of the specs, the stakeholders, never actually
read them. This pitch has a reader who does. Agents read specs every session,
forget everything at compaction, and get rotated without notice. A
repo-resident spec survives all three. And the failure mode specled targets is
exactly the agent failure mode: something plausible gets implemented, the tests
pass, and the divergence surfaces six weeks later on merge.

The piece models can't outgrow is the gate. Prose context loses value as
models get better at inferring intent from code and tests. A mechanical merge
gate doesn't care how smart the model is. If you're weighting investment,
weight the gate, not the prose.

## Is it overengineered

Partly, and the repo tells you exactly where. 34 subjects carrying 10,723
lines of spec prose, 66 ADRs at another 5,406 lines, against 31,399 lines of
implementation. 18 mix tasks, five realization tiers, three verification
strengths, a dozen branch-guard codes, escape hatches with their own severity
semantics. Roughly one line of governance prose for every two lines of code,
on a plain Mix library with no Phoenix and no database. When the ADR corpus
contains `append_only_finding_budget` v1, v2, and v3, the meta-process is
writing ADRs about its own budget, and the audience for new machinery is the
author, not adopters. The `realization_hashes.json` merge rules are the
clearest single smell. A derived bookkeeping file that needs two paragraphs of
conflict guidance, including which labeled side to prefer, taxes every
multi-branch workflow that touches it.

The defense, and it's a real one, is that the design knows. The adoption doc
says skip the implementation tier indefinitely, skip triangulation
indefinitely, the core loop never grows past four commands. Degrade paths
instead of failures, escape hatches labeled as "honesty debt," evidence
explicitly forbidden as gate input. That honesty is rare in this tool category
and it's the strongest quality signal here. But layered design still costs the
maintainer. You maintain all the layers even when adopters use two.

## Why adopt it, running an Elixir shop

The BEAM ecosystem has no living spec convention. Cabbage and Gherkin never
took hold, so the niche is genuinely empty, and specled's ExUnit integration
(tag scanning, aggregated test runs, coverage ingestion) is deeper than
anything language-agnostic will ever reach in Elixir. For an agent-heavy shop
the biggest single win is that the merge gate is agent-proof. An agent
claiming done gets verified mechanically and can't argue with
`spec.check result=`. A human reviewer can be talked out of a suspicion. The
gate can't.

Why not: double bookkeeping. Every behavior change now touches spec prose,
tags, possibly the hash baseline, code, and tests. If the spec mostly restates
what a test asserts, you've built two sources of truth and one will rot. A
stale spec is worse than no spec, because agents treat it as authoritative and
will confidently implement the wrong thing from it. The append-only guardrails
catch deletion and downgrade, not staleness of intent. Also concretely:
v0.17.0, single maintainer, no Hex package, distributed as a path or GitHub
dep, one native NIF pulled in to render a review artifact. Exit cost is
bounded since the artifacts are plain Markdown and the dep is
`runtime: false`. But you'd be betting shop process on a pre-1.0 tool.

## Better alternative

The real competitor isn't another framework. It's AGENTS.md plus disciplined
ExUnit plus CI, which gets most of the durable-intent value at a fraction of
the cost. That's the right default for a shop that has never been burned by
the specific gap specled closes. If you want industry momentum instead, GitHub
Spec Kit or Kiro, but neither is wired to ExUnit and neither gives you a
mechanical gate against your actual suite. Skip Cucumber-shaped BDD entirely;
ceremony without an audience. StreamData is complementary, not a substitute.

The decision rule I'd use: adopt specled when "the tests were green but the
behavior was wrong" has cost you real money at least twice. Below that
threshold, the zero-framework version wins.

## Would it just burn tokens

The protocol itself is cheap, and the cadence ladder shows someone thought
about it. A subject averages ~315 lines, so reading one or two runs 3 to 8k
tokens, once per session with prompt caching. `spec.prime` prints a page.
Checks are commands with truncated output, and `--no-run-commands` exists
precisely to keep mid-iteration cheap. Compare that to the alternative, an
agent reading lib code cold to reconstruct intent. That costs more tokens and
produces worse behavior.

The burn risk is sprawl, not protocol. This repo's 16k lines of governance
prose is the cautionary number. An agent that must read five subjects per task
pays that tax every session forever. Net: no, it doesn't just burn tokens, if
you spec the domains where drift hurts and keep the specs short. It absolutely
does if you spec everything.

## Tiers of adoption vs tiers of value

These are not aligned, and that's the most important thing to see. Value
saturates early, cost keeps climbing.

- **`surface:` carving only** (brownfield Phase 1). Spec files name their
  modules, `spec.next` routes edits back to subjects, unmapped changes warn.
  No hashing, no enforcement. This is where you learn whether the discipline
  fits your team at all.
- **The core triangle** (Phases 2–3). `api_boundary` hashes, `@tag spec:`
  linkage, `spec.check` in CI at warning severity, graduating to error. This
  is the maximum value per unit of cost in the entire system and the right
  adoption target for most shops. It catches the requirement with no test,
  the deleted MFA, the drifted function head.
- **Coverage triangulation** (Phase 4a/4b). Diagnostic only, never gates.
  Real value in brownfield discovery, which modules have no coverage at all,
  and in tests claiming one subject while executing another. Per-test
  attribution costs serialized runs and wiring. Adopt only if that specific
  lie has already burned you.
- **Implementation-tier closure walking and beyond** (Phase 5). Compile tracer
  on every build. The docs themselves say skip it indefinitely. Refactor-heavy
  codebases only.

Concrete path: pick the two or three modules with the most churn or the most
painful regressions, write characterization specs for what they do today, tag
the tests that already exist, put `spec.check` in CI at warning for a month,
and graduate to error only the codes that fired truthfully. Never spec CRUD.
Never spec glue.

## Closing note to the maintainer

The value concentrates in the gate. If you keep building, make the gate
unmissable and cheap, and resist tier creep; the ADR count is your canary. And
if you want adopters beyond your own checkouts, a Hex release matters more
than any new tier, because a path dependency is a bigger adoption barrier than
any missing feature.
