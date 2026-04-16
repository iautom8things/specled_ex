# Changelog

## Unreleased

- Added opt-in test-tag scanning that links requirements to the tests that cover them. `SpecLedEx.TagScanner` walks configured test directories via `Code.string_to_quoted/2` (no compilation) and extracts ids from `@tag spec: "<id>"`, `@tag [spec: ..., ...]`, `@tag spec: ["a", "b"]`, and `@moduletag spec` annotations. Scanner output flows through the index and powers four new verifier findings (`requirement_without_test_tag`, `verification_cover_untagged`, `tag_scan_parse_error`, `tag_dynamic_value_skipped`) and one new branch-guard finding (`branch_guard_requirement_without_test_tag`) for new `must` requirements added on the current branch.
- Added `SpecLedEx.Config`, a workspace-scoped config loader for `.spec/config.yml` with keys `test_tags.enabled` (boolean), `test_tags.paths` (list of strings), and `test_tags.enforcement` (`warning` | `error`). Missing or malformed config degrades to defaults; unknown enforcement values log a warning. `mix spec.init` now scaffolds `.spec/config.yml` alongside the rest of the workspace.
- Added `--test-tags` / `--no-test-tags` flags on `mix spec.check` and `mix spec.validate` to override the workspace config for a single invocation. Precedence is CLI flag > `.spec/config.yml` > built-in default.
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
