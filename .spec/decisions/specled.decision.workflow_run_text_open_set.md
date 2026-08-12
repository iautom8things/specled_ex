---
id: specled.decision.workflow_run_text_open_set
status: accepted
date: 2026-08-12
affects:
  - specled.spec_review.gh_pages_privilege_separation
change_type: narrows-scope
---

# Workflow `run:` Text Is Not a Mechanical Privilege Boundary

## Context

The seeded spec-review workflow separates rendering untrusted pull-request
code from deploying the resulting artifact. A command-tier test was added to
guard that separation, including the rule that the write-scoped deploy job
must not check out or execute pull-request-provided code.

Three iterations attempted to prove that rule by recognizing dangerous
commands in YAML `run:` strings. Each iteration denied more spellings while
leaving equivalent ones unrecognized. Absolute executable paths,
alternative Git verbs, shell indirection, aliases, interpreters, and encoded
commands all demonstrate the underlying problem: shell text has an open set
of ways to express checkout and execution semantics.

A growing matcher over command spellings therefore cannot establish the
absolute security property. Passing that matcher would say only that no
known spelling was present, while the requirement and verification coverage
would imply substantially more.

The workflow still has several properties that are directly represented in
its parsed YAML structure. Those properties can be checked without claiming
to interpret shell programs:

- top-level permissions are exactly read-only;
- the only jobs are render and deploy, with deploy depending on render;
- render has no write scope and deploy holds the required write scopes;
- deploy's `uses:` actions and their `with:` keys are allowlisted;
- the deploy checkout action is pinned to the trusted base ref; and
- operands on the workflow's known `git fetch` and `git worktree add`
  acquisition lines are allowlisted.

## Decision

The command-tier guard for
`specled.spec_review.gh_pages_privilege_separation` enforces only those
structurally checkable properties. It does not scan arbitrary `run:` text for
checkout-class verbs, PR-head fragments, invocations of Mix, interpreters,
or execution from the downloaded artifact path.

The operand allowlist remains intentionally narrow. Its selector identifies
the workflow's existing `git fetch` and `git worktree add` command shapes so
their operands cannot drift unnoticed; it is not evidence that all possible
acquisition or execution commands have been discovered.

The workflow's architectural separation remains the desired behavior. The
test's claim is narrower: it detects structural erosion of the represented
boundary, not semantic equivalence across arbitrary shell programs.

## Consequences

- Positive: verification no longer overstates what a text matcher can prove.
- Positive: the stable YAML structure remains guarded with exact,
  deny-by-default allowlists where the input domain is closed.
- Positive: routine failures point to concrete structural drift rather than
  a perpetually incomplete vocabulary of dangerous command spellings.
- Negative: a malicious or mistaken edit expressed only through novel
  `run:` text may evade this command-tier test.
- Negative: fully enforcing the residual security property requires a
  different boundary, such as eliminating PR-derived inputs from the deploy
  job or allowlisting the complete deploy script, rather than extending this
  matcher.
- Follow-up changes must not describe this guard as proving that deploy
  cannot execute PR-provided code. They may still preserve or strengthen the
  workflow architecture itself.
