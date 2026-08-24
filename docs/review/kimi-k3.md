# Honest Assessment of specled

Reviewer: Kimi K3 (`moonshotai/kimi-k3`)
Date: 2026-08-20

Grounded in the README, `docs/adoption.md`, a sample spec
(`binding.spec.md`), and code sizing: ~31k lines of library code, ~39k lines
of tests, 18 mix tasks, 34 spec subjects totaling ~10.7k lines of spec
markdown, and 66 ADRs in this repo.

## The verdict

The pattern is worth adopting for an agent-heavy Elixir shop, and specled is
one of the only executable versions of it. The full system is more than most
shops need, but it is bought in rungs, not all at once. The overengineering
lives in the drift-hash subsystem, and even there it is the kind of
overengineering that still has a consumer. I would call it ambitious rather
than wasteful.

## The problem is real

The failure mode specled targets is the one that actually bites in
agent-authored code. Tests pass, but the tests no longer encode intent, so
the agent satisfies a contract nobody agreed to. "Tests are the source of
truth" is weak because tests say nothing about which behavior matters or why.
"Spec files bind tests and code MFAs with executable checks" is a real
answer, and almost nobody else ships that. Requirements traceability is a
genuine discipline that usually lives in enterprise tooling. Specled shrinks
it to repo scale.

## Is it overengineered?

Parts of it. The thing that smells is the realization-drift machinery:
beam-first lookup with source-AST fallback, canonicalized AST hashing with
α-renaming, plus resolution-path provenance to label which lookup produced
the hash. That last part is an ADR solving a problem the hashing created,
which is a classic sign of a subsystem that outgrew its problem.

Two things soften the verdict.

First, the drift hashing genuinely reduces false positives. A cosmetic
refactor of a bound function does not trip the gate; a semantic change does.
File-granularity mapping alone cannot tell those apart, so the hash earns
its keep for any adopter past a handful of subjects.

Second, and this is the best design decision in the product, every detector
degrades to a `detector_unavailable` finding instead of failing the build.
That is what makes partial adoption safe, and it is what most gating tools
get wrong. A gate that fails closed when its prerequisites are missing
teaches people to disable the gate.

The 66 ADRs dogfooding the tool itself is a lot, but this repo is the
showcase. A shop adopting would not carry that weight.

## Does it burn tokens?

No, on balance it saves them. `mix spec.prime` prints a bounded snapshot. An
agent reads two or three small spec files instead of re-reading whole modules
to infer intent. `mix spec.check` runs local commands and returns an exit
code. The review HTML is for humans. The token cost lives in maintaining
specs and ADRs, and you pay that cost for any durable convention. The
expensive alternative is debugging generations that drifted from intent,
which costs far more tokens than a spec edit.

## Better alternatives?

The realistic alternatives, ranked.

1. Prose conventions (CLAUDE.md or AGENTS.md) plus CI on tests. Most shops
   do this. It works until the agent half-follows the convention, because
   prose is a soft contract. Specled's whole point is making the contract
   executable.
2. Gherkin/BDD tooling (ExCucumber and friends). That road has been tried.
   Feature files became toil and died. The risk applies here too: if
   updating specs is annoying, people bypass and the system becomes
   ceremonial. `spec.next` mitigates this by naming exactly what to update,
   but the risk never disappears.
3. Roll your own smaller gate: subject mapping plus unmapped-change plus
   tag-presence checks, skipping drift hashing. That is maybe 80% of the
   value at 30% of the machinery. But then you maintain the gate. Using
   specled's lighter rungs is usually cheaper than writing that.

If you strip specled down to "subject IDs, `@tag spec:` on tests, CI gates
on tag presence and unmapped changes," you have a simpler product covering
most of the discipline. The rest is a precision instrument you buy when
refactors keep false-flagging the gate.

## Should an Elixir shop adopt it?

Adopt the pattern in tiers. Do not necessarily take the full payload. Team
shape decides: a small shop with one senior dev and no agents pays overhead
it does not need, while an agent-heavy shop rewrites code at machine speed
and the executable contract pays for itself fast.

## Tiers of value

The docs encode the tiers well: `realized_by` tiers opt in in order, and
detectors degrade rather than fail when prerequisites are missing.

**Tier 0, one afternoon.** Run `mix spec.init`, write specs for two or three
subjects with prose only, run `mix spec.validate`. The value is
machine-readable intent at almost no cost.

**Tier 1, the sweet spot.** Add `@tag spec:` to new tests and gate CI on tag
presence plus unmapped change. Now every `must` requirement has a test claim
and every changed file lands somewhere. This is where I would start, and
where most shops should live for a while.

**Tier 2.** Add `realized_by:` implementation bindings so drift detection
comes online, and use ADRs for cross-cutting changes. The gate now survives
refactors and catches edits to bound functions that skip the spec.

**Tier 3.** Coverage triangulation and the review artifact. Nice for big
teams. Skip for most.

Brownfield adopters should phase gates in per PR, as the adoption doc says.
Greenfield should turn on everything day one. Greenfield is where specled
shines because there is no retrofit toil.

## What to watch

Spec rot. The day a shop starts merging with `--no-run-commands` by default,
or tagging tests without reading the requirement the tag names, the system
becomes ceremony. Start at Tier 1 and let the gate prove it catches real
drift before climbing.

## Bottom line

Adopt the pattern. Specled is a credible, unusually careful implementation
of it. Buy it a rung at a time, lean on the degrade-not-fail design while
you climb, and treat the drift-hash machinery as something you grow into
rather than something you install on day one.
