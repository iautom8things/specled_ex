<!-- agent-rules: generated v0.14.0 -->
# Agent Rules

This repo uses the portable agent-rules package.

Grok currently does not receive hook `additionalContext`, so dynamic rules are not injected into model context.
When a command or file path appears to match one of these rules, read the listed file before acting.

| Rule | Source | Covers |
| --- | --- | --- |
| `beadwork` | `.claude/rules/beadwork.md` | Work tracking with bw (beadwork). Persists plans, progress, and decisions to git across sessions. |
| `specled` | `.claude/rules/specled.md` | Specled — repo-resident behavioral specs and the verification loop. Specs are the source of truth for "what must be true." |
| `testing` | `.claude/rules/testing.md` | ExUnit test patterns. Test cases, Mox, Oban, process lifecycle, LiveView assertions. |
| `worktree` | `.claude/rules/worktree.md` | Worktree-first workflow for host-run Elixir projects. |
| `elixir-patterns` | `.claude/dynamic-rules/elixir-patterns.md` | Elixir language patterns. Timeouts, behaviour impls, list access, immutability, guards, OTP primitives. |
| `worktree-admin-host` | `.claude/dynamic-rules/worktree-admin-host.md` | Worktree admin and cleanup make targets in host-run repos (host-shell / host-go / host-elixir). |
| `worktree-cleanup` | `.claude/dynamic-rules/worktree-cleanup.md` | Hard gate — raw `git worktree remove` / `git worktree prune` are blocked; use `make worktree-cleanup` / `make worktree-prune`. |
| `worktree-create-host` | `.claude/dynamic-rules/worktree-create-host.md` | Creating linked worktrees in host-run repos (host-shell / host-go / host-elixir) — branch source and the seed check. |
| `worktree-smoke-host` | `.claude/dynamic-rules/worktree-smoke-host.md` | Readiness gate before implementation work in host-run repos (host-shell / host-go / host-elixir). |
