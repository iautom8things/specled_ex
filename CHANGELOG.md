# Changelog

## Unreleased

- Added durable ADR support under `.spec/decisions/*.md`, including `mix spec.adr.new`, decision indexing in `.spec/state.json`, subject-to-ADR references through `spec-meta.decisions`, and verifier checks for ADR structure, affects, and supersession links.
- Added `mix spec.report` and `mix spec.diffcheck` so repositories can summarize current coverage and enforce diff-aware co-changes without introducing persistent in-flight `.spec` artifacts.
- Changed `mix spec.init` to scaffold `.spec/decisions/README.md` and refreshed the generated local Skill guidance around ADRs, current-truth subject updates, `mix spec.report`, and `mix spec.diffcheck`.
- Added an interactive `mix spec.init` prompt that can scaffold a local Skill for Spec Led Development alongside the `.spec/` starter workspace.
- Changed `mix spec.init` to scaffold both `.spec/README.md` and `.spec/AGENTS.md`, keeping human-facing workspace docs and agent-facing operating guidance separate.
- Tightened the package's self-hosted specs to prefer targeted command verifications for behavior-heavy subjects, so `mix spec.check` passes cleanly under strict file-reference linking.
- Promoted `verification_target_missing_reference` from `info` to `warning`, so strict verification now fails when file-backed verification targets do not mention the ids they claim to cover.
- Changed `mix spec.check` to execute eligible `kind: command` verifications by default while keeping `mix spec.verify` command execution opt-in.
- Added verification strength reporting with `claimed`, `linked`, and `executed` levels plus `--min-strength` / `spec-meta.verification_minimum_strength` thresholds.
- Made `.spec/state.json` canonical and diff-friendly by removing volatile persisted fields, sorting output deterministically, and skipping no-op rewrites.
