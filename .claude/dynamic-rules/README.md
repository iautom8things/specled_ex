# `.claude/rules/` and `.claude/dynamic-rules/`

Project conventions auto-injected into the Claude Code agent via a PreToolUse
hook. Each `*.md` file is one rule.

Two directories, same frontmatter and matching logic, different loading:

- **`.claude/rules/`** — also auto-loaded in full by Claude Code's own native
  rules loader when a rule has no `paths:` field (see Claude Code's docs on
  `.claude/rules/`). Rules with `paths:` here are also lazily loaded natively
  when Claude reads a matching file, in addition to firing via this hook on
  Edit/Write.
- **`.claude/dynamic-rules/`** — invisible to Claude Code's native loader;
  only this hook reads it. **Required** for kinds of rule that must not load
  more often than intended:
  - command-gated rules (`gate_*` / `deny_gate_*` / legacy `match_command:` /
    `deny_command:`) — native Claude Code has no concept of command matching,
    so a command-only rule left in `.claude/rules/` would load in full every
    session instead of only when the command runs.
  - `write_only: true` + `paths:` rules — writing conventions with no
    read-time value. In `.claude/rules/` the native loader would inject them
    on every matching *read*; here they fire only on Edit/Write/MultiEdit.
  - `reference_only:` rules — long-form reference material that should not
    auto-load at all, surfaced instead via a `CLAUDE.md` pointer.

  `sync-agent-rules --adopt` routes all of these here automatically.

**Deny-once guarantee.** A path-gated rule in `.claude/dynamic-rules/` has no
read surface, so plain `additionalContext` would arrive only *after* the first
matching write executed (the intercepted tool call is already authored when a
PreToolUse hook runs). To guarantee conventions land first, the hook *denies*
the first matching Edit/Write/MultiEdit of a session, carrying the rule text in
the deny reason with explicit "this is not a permission problem — re-attempt
the write" framing. The dedup marker is written at deny time, so the retry
passes. One deny per rule per session per repo; rules in `.claude/rules/` and
Bash command matches are never denied that way (command *deny gates* are a
separate surface — see below).

## Frontmatter Schema

```yaml
---
description: Short summary. Surfaced in audit listings.
paths:                       # Optional. Glob patterns (gitignore-style).
  - "lib/**/*.ex"            # Paired with Edit/Write/MultiEdit.
match_content:               # Optional. Python regex. If present, file must
  - "use Foo\\.Schema"       # match at least one pattern (paths-mode only).
  - "^\\s*schema \""

# Preferred: structured gates (token membership after shell tokenization)
gate_command:                # argv[0] basename patterns (fnmatch)
  - "make"
gate_args_any:               # >=1 pattern hits >=1 arg token
  - "worktree-new"
gate_args_all: []            # EVERY pattern hits >=1 arg token

deny_gate_command:           # deny surface (same shape)
  - "git"
deny_gate_args_all:
  - "worktree"
deny_gate_args_any:
  - "remove"
  - "prune"
deny: once                   # "once" (default) educate-then-trust;
                             # "always" blocks every match. Grok never denies.

# Golden examples — required when structured gates are present
should_deny:
  - "git worktree remove ../foo"
  - "git -C /repo worktree prune"
should_match:
  - "make worktree-new BRANCH=x"
should_not_match:
  - "git commit -m 'never run git worktree remove'"
  - "rg 'git worktree remove' docs/"

# Legacy raw-regex escape hatch (prefer structured gates)
match_command:
  - "git\\s+worktree\\s+remove"
deny_command:
  - "(^|&&|;|\\|)\\s*git\\s+worktree\\s+(remove|prune)\\b"

write_only: true             # Writing conventions — dynamic-rules only. Needs paths:.
reference_only: true         # Long-form reference — never auto-loaded; CLAUDE.md pointer.
---
```

Fields combine like this:

- No `paths:` and no command surface → never auto-injected by this hook. Such a
  rule still loads *natively* in full every session when it lives in
  `.claude/rules/` — correct for an always-on mandate, wrong for reference
  material. Mark genuine reference material `reference_only: true` so
  `sync-agent-rules` installs it under `.claude/dynamic-rules/` (out of the
  native loader's sight) and maintains a `CLAUDE.md` pointer row to it.
- `paths:` only              → path glob match is enough.
- `paths:` + `match_content:` → path AND content must both match.
- command surface only, or combined with `paths:` → command match is enough on
  its own; belongs in `.claude/dynamic-rules/`.

### Why structured gates

Gates match **whole tokens** after a shell-aware tokenizer (heredocs stripped,
env-prefix/`sudo`/`command` wrappers dropped, operators split). That means:

- `git -C /path worktree remove x` is denied by `git + worktree + remove/prune`
  (argument-variation safe)
- `git commit -m "never run git worktree remove"` and
  `rg 'git worktree remove' docs/` do **not** match (quoted-data safe)

Avoid `*foo*` fnmatch patterns — they re-open the quoted-data hole. Prefer
literal tokens. Legacy `match_command:` / `deny_command:` regexes remain as an
escape hatch for shapes tokenization cannot see (e.g. `bash -c` inners).

## File Provenance

Each rule file's first line indicates how it's maintained:

| Header | Meaning | Sync behavior |
| --- | --- | --- |
| `<!-- agent-rules: generated vX.Y.Z -->` | Rendered from a central template | Re-rendered on sync |
| `<!-- agent-rules: ejected vX.Y.Z @ DATE -->` | Was central, now repo-owned | Never touched |
| _(no header)_ | Repo-only, hand-authored | Never touched |

## Debug

| Command | What it does |
| --- | --- |
| `.claude/scripts/rules-check <file>` | which rules fire for that path |
| `.claude/scripts/rules-check --command "..."` | full matcher (deny + context gates and legacy regexes); DENY hits labeled |
| `.claude/scripts/rules-check --examples` | run every golden; exit 1 on any FAIL |
| `.claude/scripts/rules-check --list` | every rule's gates, deny strength, example count |

## Cache

The hook deduplicates within a session — each rule is injected at most once per
`session_id`, scoped per repo. Marker files live under
`${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/claude/<session_id>/<repo_hash>/`
and are removed by the `SessionEnd` hook.

## Adding A New Rule

**Agents: context is a budget.** Every always-on rule taxes every session,
relevant or not. Before writing a rule, interview the user to hyper-focus its
loading — do not default to always-on, and do not guess the gates. Ask:

1. **"When should this rule be loaded?"** Every session? Only when touching
   certain code? Only when a certain command is about to run? Only on request?
2. **"Is this read-relevant, or does it only matter when writing?"**
   Conventions that shape how code is *authored* (schema macros, test
   patterns) are usually `write_only: true`. Rules that shape how code is
   *understood* (specs are source of truth, how to read the test suite)
   should stay read-triggered in `.claude/rules/`.
3. **"Are there specific files or globs this applies to?"** Tighter `paths:`
   beat broad ones — `config/dev.exs` loads far less often than `lib/**/*.ex`.
4. **"Is there a content pattern we can grep for, so it only fires on files
   that actually contain the thing?"** `match_content:` (e.g.
   `use Ecto\.Schema`) is the sharpest path gate — prefer it whenever
   the rule targets a construct rather than a location.
5. **"Is there a command that should trigger it?"** Prefer a **structured
   gate** (`gate_command` + `gate_args_*`) over a raw regex. The default
   answer to "can this be a structured gate instead of a regex?" is **yes**
   unless the trigger lives inside a string tokenization cannot see.
6. **"Is the command itself the mistake?"** If the rule exists to stop a
   command from running at all — not to annotate it — use `deny_gate_*` with
   `deny: once` (usually-wrong, educate then trust) or `deny: always`
   (never right directly; a sanctioned alternative exists). Remember
   context injection arrives *after* the command ran; only a deny
   actually prevents it.
7. **"What are the goldens?"** Every structured-gate rule needs at least one
   `should_not_match` covering a quoted mention (rg pattern / commit
   message). Deny rules also need `should_deny` covering `-C` / chained
   variants. Sync refuses to ship a gate-bearing central rule without them.

Then route by the answers:

| Answers point to | Frontmatter | Directory |
| --- | --- | --- |
| Always, it's a mandate | no gating fields | `.claude/rules/` |
| Reading or writing matching files | `paths:` (+ `match_content:`) | `.claude/rules/` |
| Only writing matching files | `paths:` (+ `match_content:`) + `write_only: true` | `.claude/dynamic-rules/` |
| A command about to run (annotate) | `gate_command:` (+ `gate_args_*`) | `.claude/dynamic-rules/` |
| A command that must be stopped | `deny_gate_command:` (+ args) + `deny: once\|always` | `.claude/dynamic-rules/` |
| On request only (reference) | `reference_only: true` | `.claude/dynamic-rules/` |

**CLAUDE.md table.** Only `reference_only: true` rules get a row in the
`agentic.rules` block of `CLAUDE.md` — that pointer *is* their load mechanism.
Hook-gated, write-only, and always-on rules do **not** get a CLAUDE.md row
(they are already delivered by the PreToolUse hook or the native loader). Use
`.claude/scripts/rules-check --list` for the full catalog.

Mechanics:

1. Drop a new `<name>.md` with frontmatter in the directory from the table.
2. Run `.claude/scripts/rules-check --command "..."` and `--examples` to
   confirm it fires (and only fires) where intended.
3. Commit. The hook picks it up on the next session.

If your rule applies to multiple repos, consider promoting it to the central
library in `agentic-dotfiles` so other projects can adopt it via
`sync-agent-rules --adopt <name>`.
