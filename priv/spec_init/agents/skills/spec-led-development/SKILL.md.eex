---
name: spec-led-development
description: Help maintain the local `.spec/` workspace for Spec Led Development. Use when creating or revising subject specs, aligning specs with code, tests, and guides, adding or revising durable ADRs, fixing `mix spec.verify`, `mix spec.check`, or `mix spec.diffcheck` findings, or checking for drift in `.spec/specs/*.spec.md`.
---

# Spec Led Development

Use this Skill when working on the local `.spec` workspace.

## Workflow

1. Read `.spec/README.md`, `.spec/decisions/README.md`, and the current `.spec/specs/*.spec.md` files before editing.
2. Keep one subject per file. Update an existing subject when the change fits its boundary. Add a new subject only when the behavior is distinct.
3. Ground requirements and scenarios in repository evidence from `lib/`, `guides/`, and `test/`.
4. Add or revise an ADR in `.spec/decisions/*.md` only when the rule is cross-cutting and should remain durable after the branch merges.
4. Prefer YAML fenced blocks and stable lowercase ids.
5. Choose the smallest reliable verification target.
   - Prefer targeted command verifications for behavioral checks.
   - Use file-backed targets only when the target can carry stable `covers:` markers for the ids it names.
6. After changes run:
   - `mix spec.verify --debug`
   - `mix spec.check`
   - `mix spec.diffcheck` when code, docs, or tests changed
   - `mix spec.report` when you need a coverage summary
7. Fix warnings as well as errors.

## Local Inputs

- `.spec/README.md`
- `.spec/decisions/README.md`
- `.spec/decisions/*.md`
- `.spec/specs/*.spec.md`
- `.spec/state.json` when present

## Authoring Reminders

- Put normative statements in `spec-requirements`.
- Use `spec-scenarios` only when `given` / `when` / `then` improves clarity.
- Use `spec-meta.decisions` only for durable cross-cutting ADR references.
- Keep verification targets repository-root-relative.
- Avoid duplicate subjects for the same boundary.
- Keep `.spec` declarative and current-state only. Use Git history for the timeline of change.
