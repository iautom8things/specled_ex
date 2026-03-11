# Changelog

## Unreleased

- Promoted `verification_target_missing_reference` from `info` to `warning`, so strict verification now fails when file-backed verification targets do not mention the ids they claim to cover.
- Changed `mix spec.check` to execute eligible `kind: command` verifications by default while keeping `mix spec.verify` command execution opt-in.
- Added verification strength reporting with `claimed`, `linked`, and `executed` levels plus `--min-strength` / `spec-meta.verification_minimum_strength` thresholds.
- Made `.spec/state.json` canonical and diff-friendly by removing volatile persisted fields, sorting output deterministically, and skipping no-op rewrites.
