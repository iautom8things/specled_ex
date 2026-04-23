---
id: specled.decision.file_backed_linked_strength
status: accepted
date: 2026-03-11
affects:
  - repo.governance
  - specled.verification
  - specled.parser
change_type: clarifies
---

# File-Backed Linked Strength Requires Literal Ids

## Context

File-backed verification is useful for stable references, but it becomes ambiguous when a target file does not literally name the ids it claims to cover.

## Decision

Treat file-backed verification as linked strength only when the target content literally includes each covered id. Prefer command verification for behavior-heavy checks when adding literal ids to the target would be noisy or unstable.

## Consequences

The verifier stays deterministic, and authors have a clear rule for when to choose command-based evidence instead of trying to force file markers into production code or tests.
