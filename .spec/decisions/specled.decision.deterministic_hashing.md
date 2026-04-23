---
id: specled.decision.deterministic_hashing
status: accepted
date: 2026-04-21
affects:
  - specled.binding
  - specled.api_boundary
  - specled.implementation_tier
  - specled.expanded_behavior_tier
  - specled.use_tier
change_type: clarifies
---

# All Hash Inputs Serialize Via `:erlang.term_to_binary/2` With `[:deterministic, minor_version: 2]`

## Context

Red-team 04a#m1 flagged that `term_to_binary/1` default encoding is not
guaranteed stable across OTP releases or OS flavors. SpecLedEx stores hashes
committed to git; a non-deterministic serialization means an OTP minor bump
or a developer switching OS can spontaneously flip every hash, producing a
flood of fake drift findings and destroying user trust.

OTP 24+ supports the `:deterministic` option which guarantees a canonical
byte-for-byte encoding independent of runtime. The project's OTP 27 target
satisfies this; `minor_version: 2` additionally fixes float encoding to a
stable representation.

## Decision

Every call to `:erlang.term_to_binary/2` used in a hash-input pipeline —
canonical AST serialization, expanded_behavior debug_info dumping, typespec
hashing, use-tier provider composition — shall pass the options list
`[:deterministic, minor_version: 2]`. No hash-producing code path omits these
options.

This is enforced at code-review time. If future OTP versions introduce a newer
minor_version with stability improvements, the bump is gated by a
`hasher_version` attribute bump (silent internal rehash; no user-visible
finding).

## Consequences

- Positive: hashes survive OTP minor bumps and OS changes without producing
  phantom drift.
- Positive: single documented option pair — no call-site-specific variations.
- Negative: OTP 23 and older are unsupported for hashing. This is aligned with
  `deps.allowed` policy (Elixir ~1.17+; OTP 27 in practice).
