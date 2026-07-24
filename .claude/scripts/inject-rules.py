#!/usr/bin/env python3
# agent-rules: generated v0.13.1
"""Inject matching .claude/rules/*.md and .claude/dynamic-rules/*.md files into
agent context once per session.

Wired as a PreToolUse hook matched on Edit|Write|MultiEdit|Bash|apply_patch.
Reads the hook payload from stdin, iterates this repo's
.claude/rules/*.md and .claude/dynamic-rules/*.md files, and emits any whose
frontmatter matches the tool call.

Two source directories are scanned, same frontmatter and matching rules for
both:

    .claude/rules/          Also auto-loaded in full by Claude Code's native
                             CLAUDE.md loader when a rule has no `paths:`
                             field (see Claude Code docs on `.claude/rules/`).
                             Fine for rules you want in context every session
                             regardless of this hook, or whose `paths:` gating
                             should also be enforced natively.
    .claude/dynamic-rules/  Invisible to Claude Code's native loader — only
                             this hook reads it. Required for any rule gated
                             by `match_command:`, since native Claude Code has
                             no concept of command matching and would load a
                             match_command-only rule unconditionally every
                             session if it lived in .claude/rules/ instead.
                             Also holds `write_only: true` paths-gated rules:
                             writing conventions that shouldn't pay native
                             read-triggered loading.

Deny-once guarantee: a paths-gated rule living in .claude/dynamic-rules/ has no
native read surface, so without intervention its content would arrive only
AFTER the first matching write executed (PreToolUse additionalContext is
delivered with the tool result — the tool call it intercepts was already
authored). To guarantee the conventions land BEFORE the first write, a
path-mode match on a dynamic-rules rule DENIES that one tool call, carrying the
rule content in permissionDecisionReason with framing that tells the agent to
re-attempt the write. The dedup marker is written at deny time, so the
reattempt matches nothing and proceeds. One deny per rule per session per repo.
Rules in .claude/rules/ keep plain additionalContext (their native read-trigger
is the primary surface); Grok sessions never deny (the Grok adapter has no deny
contract).

Command gates: `deny_command:` patterns mark a Bash command as itself being the
mistake — a match DENIES the command with the rule body as the reason, framed
as "use the sanctioned alternative; rephrase if the match is incidental."
`deny: once` (default) educates then stands down for the session; `deny:
always` blocks every match, with a short reminder after the first. Plain
`match_command:` matches are never denied — their context arrives with the
tool result, after the command ran.

Three surfaces are supported:

    Edit/Write/MultiEdit -> match against `tool_input.file_path`
                            via `paths:` globs and optional `match_content:` regex.
    Bash                 -> match against `tool_input.command`
                            via `deny_command:` (checked first) or
                            `match_command:` regex (Python re, multiline).
    apply_patch          -> extract patch header paths from `tool_input.command`
                            and match them as path-mode edits. `Add File` paths
                            skip `match_content` because no file exists yet.

Each (session_id, repo_root, rule_name) triple is injected at most once across
all surfaces. Marker files at
${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/<agent>/<session_id>/<repo_hash>/<rule_name>
track state across hook firings within a session; <agent> is `claude`, `codex`,
or `grok` (see `detect_agent()` below) and defaults to `claude`. The <repo_hash>
segment (a short sha256 of the resolved repo root) scopes markers per repo, so a
same-named rule adopted in two repos does not collide within one session. The
companion prune-rules-cache hook removes stale session directories (all three
agent segments) on SessionStart; clear-rules-cache.sh stays installed as a
non-destructive deprecated compatibility hook for repos still registered on the
older SessionEnd path.

Frontmatter schema (YAML between leading --- lines):

    description: Human-readable summary.
    paths:                    # optional. globs. paired with file_path tools.
      - "lib/**/*.ex"
    match_content:            # optional. regex. file must match >=1 (path-mode only).
      - "use Builder\\\\.Schema"
      - "^\\\\s*schema \\""
    match_command:            # optional. regex. matched against Bash tool_input.command.
      - "git\\\\s+worktree\\\\s+remove"
    deny_command:             # optional. regex. a matching Bash command is DENIED,
      - "..."                 # with the rule body as the deny reason — for commands
                              # that are themselves the mistake. Anchor patterns to
                              # command position to limit false matches.
    deny: once | always       # optional. deny_command strength. "once" (default)
                              # blocks the first match then stands down for the
                              # session; "always" blocks every match.
    write_only: true          # optional. not read by this hook — tells
                              # sync-agent-rules to install the rule under
                              # .claude/dynamic-rules/ (write-triggered only).

A rule with none of `paths:`, `match_command:`, or `deny_command:` is never
auto-injected — useful for workflow rules loaded via CLAUDE.md references.

Stdout is the hook's contract surface. Exit 0 with empty stdout means "no rules
matched, continue silently." Errors go to stderr and exit 0 so the hook never
blocks tool calls; missing inputs are treated as no-op.
"""
from __future__ import annotations

import fnmatch
import hashlib
import json
import os
import re
import shlex
import sys
from pathlib import Path
from typing import NamedTuple

AGENT_CLAUDE = "claude"
AGENT_CODEX = "codex"
AGENT_GROK = "grok"
DEFAULT_AGENT = AGENT_CLAUDE
SUPPORTED_AGENTS = {AGENT_CLAUDE, AGENT_CODEX, AGENT_GROK}
PATCH_PATH_RE = re.compile(r"^\*\*\* (Add File|Update File|Delete File|Move to):\s*(.+?)\s*$")


class ToolPath(NamedTuple):
    file_path: str
    rel_path: str
    skip_match_content: bool = False


class PatchPath(NamedTuple):
    path: Path
    skip_match_content: bool = False

# Shell operator tokens (boundaries between simple commands). A token is an
# operator when every character is one of these; covers && || | ; & ( ).
_OPERATOR_CHARS = set("|&;()")
# Redirection ops whose following filename token is skipped for gate matching.
_REDIRECT_OPS = frozenset({"<", ">", ">>"})
# Shell reserved words stripped at command position so the simple command they
# prefix (if/while conditions, then/do bodies) still reaches gate evaluation.
_RESERVED_WORDS = frozenset(
    {"if", "then", "elif", "else", "fi", "do", "done", "while", "until", "for", "!", "{", "}"}
)
# Wrappers popped (with leading flags) before gate evaluation on argv[0].
_WRAPPER_COMMANDS = frozenset(
    {"command", "env", "sudo", "nohup", "nice", "stdbuf", "time", "timeout"}
)
# Wrapper flags that consume the following token as a value (space-separated
# form only; attached forms like -n10 / -o0 are popped by the plain flag loop).
_WRAPPER_VALUE_FLAGS = {
    "nice": frozenset({"-n", "--adjustment"}),
    "timeout": frozenset({"-s", "--signal", "-k", "--kill-after"}),
    "sudo": frozenset({"-u", "-g", "-p", "-h"}),
}
# Leading VAR=value assignments dropped before gate evaluation.
_VAR_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# Heredoc openers: <<, <<-, <<~ with optional quoted/bare delimiter.
_HEREDOC_RE = re.compile(
    r"""<<([-~]?)[ \t]*(?:'([^'\n]*)'|"([^"\n]*)"|\\?(\S+))"""
)

DENY_FRAMING_WRITE = (
    "This tool call was intentionally blocked ONE TIME by the agent-rules hook, "
    "only so that the project rules below reach you BEFORE the write lands. "
    "This is NOT a permission problem, and the same write will NOT be blocked "
    "again this session. Review the rules, adjust your change if needed, and "
    "then re-attempt the write."
)

DENY_FRAMING_COMMAND = (
    "This command was blocked by a project rule gate — the command itself is "
    "the mistake the rule exists to prevent. Read the rule below and use the "
    "sanctioned alternative instead; do NOT retry the command as-is. If the "
    "matched pattern appears only incidentally (e.g. inside a quoted string or "
    "commit message), rephrase the command so the pattern does not appear."
)


def pending_write_content(tool_name: str, tool_input: dict) -> str:
    """Return the pending write body that match_content must inspect.

    Write carries the full file in `content`. Edit carries the replacement in
    `new_string`. MultiEdit carries one `new_string` per `edits[]` entry — join
    them so a content-gated rule fires when any edit introduces the construct.
    """
    if tool_name == "Write":
        return tool_input.get("content", "") or ""
    if tool_name == "Edit":
        return tool_input.get("new_string", "") or ""
    if tool_name == "MultiEdit":
        edits = tool_input.get("edits") or []
        parts: list[str] = []
        for edit in edits:
            if isinstance(edit, dict):
                piece = edit.get("new_string", "") or ""
                if piece:
                    parts.append(piece)
        return "\n".join(parts)
    return ""


def emit_hook_output(
    injected_blocks: list[str],
    repeat_deny_lines: list[str],
    deny_worthy: bool,
    deny_framing: str,
) -> None:
    """Write already-collected rule blocks to stdout as valid hook JSON."""
    if not injected_blocks and not repeat_deny_lines:
        return
    combined = "\n\n".join(repeat_deny_lines + injected_blocks)
    if deny_worthy:
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": deny_framing + "\n\n" + combined,
            }
        }
    else:
        output = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": combined,
            }
        }
    json.dump(output, sys.stdout)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        print(f"inject-rules: invalid hook payload: {exc}", file=sys.stderr)
        return 0

    session_id = payload.get("session_id") or payload.get("sessionId") or ""
    tool_name = normalize_tool_name(payload.get("tool_name") or payload.get("toolName") or "")
    tool_input = payload.get("tool_input") or payload.get("toolInput") or {}
    payload_cwd = payload.get("cwd") or payload.get("workspaceRoot") or ""

    if not session_id:
        return 0

    agent = detect_agent(payload)
    command = tool_input.get("command", "") if tool_name == "Bash" else ""
    file_candidates = tool_path_candidates(tool_name, tool_input, payload_cwd)
    # Pending write body for all three write tools so match_content sees the
    # construct on the call that INTRODUCES it (Write content, Edit new_string,
    # MultiEdit edits[].new_string).
    pending_content = pending_write_content(tool_name, tool_input)

    if not file_candidates and not command:
        return 0

    if file_candidates and tool_name != "apply_patch":
        anchor = file_candidates[0].path.parent
    elif payload_cwd:
        anchor = Path(payload_cwd)
    else:
        anchor = Path.cwd()
    repo_root = find_repo_root(anchor)
    if not repo_root:
        return 0

    rule_dirs = [
        d for d in (repo_root / ".claude" / "rules", repo_root / ".claude" / "dynamic-rules")
        if d.is_dir()
    ]
    if not rule_dirs:
        return 0

    tool_paths = [
        tool_path
        for candidate in file_candidates
        if (tool_path := path_relative_to_repo(candidate, repo_root)) is not None
    ]

    cache_dir = cache_root() / agent / sanitize_id(session_id) / repo_marker(repo_root)
    cache_dir.mkdir(parents=True, exist_ok=True)

    injected_blocks: list[str] = []
    deny_worthy = False
    deny_framing = DENY_FRAMING_WRITE
    repeat_deny_lines: list[str] = []
    # Shared across rules so tokenize_command runs at most once per hook fire.
    token_cache: dict = {}

    try:
        rule_files = [f for d in rule_dirs for f in sorted(d.glob("*.md"))]

        for rule_file in rule_files:
            if rule_file.name == "README.md":
                continue

            rule_name = rule_file.stem
            marker = cache_dir / rule_name

            try:
                try:
                    frontmatter, body = parse_frontmatter(rule_file)
                except FrontmatterError as exc:
                    print(f"inject-rules: {rule_file.name}: {exc}", file=sys.stderr)
                    continue

                matched = match_tool_call(
                    frontmatter,
                    tool_paths,
                    command,
                    pending_content,
                    rule_name=rule_name,
                    token_cache=token_cache,
                )
                if matched is None:
                    continue
                match_reason, surface = matched

                if surface == "command-deny" and agent != AGENT_CLAUDE:
                    # No deny contract outside Claude — fall back to plain context.
                    surface = "command"

                if marker.exists():
                    # Already injected this session. Only a deny:always command gate
                    # still acts — it blocks again, with a short reminder instead of
                    # the full body.
                    if surface == "command-deny" and deny_strength(frontmatter) == "always":
                        deny_worthy = True
                        deny_framing = DENY_FRAMING_COMMAND
                        desc = frontmatter.get("description") or ""
                        repeat_deny_lines.append(
                            f"Rule `{rule_name}` (already shown this session) blocks this "
                            f"command every time: {desc}".rstrip()
                        )
                    continue

                injected_blocks.append(format_block(rule_name, match_reason, body))
                marker.touch()

                if surface == "command-deny":
                    deny_worthy = True
                    deny_framing = DENY_FRAMING_COMMAND
                elif (
                    surface == "path"
                    and rule_file.parent.name == "dynamic-rules"
                    and agent == AGENT_CLAUDE
                ):
                    # Path-mode matches from .claude/dynamic-rules/ have no native read
                    # surface — deny this one call so the rule lands before the write.
                    deny_worthy = True
            except Exception as exc:
                # One bad rule must never abort siblings or change the exit code.
                print(
                    f"inject-rules: {rule_file.name}: unexpected error: {exc}",
                    file=sys.stderr,
                )
                continue
    except Exception as exc:
        # Final guard: emit anything already collected, then fail open (exit 0).
        print(f"inject-rules: unexpected error: {exc}", file=sys.stderr)

    emit_hook_output(injected_blocks, repeat_deny_lines, deny_worthy, deny_framing)
    return 0


def detect_agent(payload: dict) -> str:
    """Return the cache agent segment (`claude`, `codex`, or `grok`) for this
    hook invocation.

    Precedence:
    1. Explicit `AGENT_RULES_AGENT` env override — set by Codex's hook wiring
       (`env AGENT_RULES_AGENT=codex ...`) and Grok's adapter
       (`AGENT_RULES_AGENT=grok ...`). An unsupported value is a warning plus
       default-to-claude, never a hard failure (the hook must stay fail-open).
    2. Grok auto-detection, for the case no explicit override is present:
       `GROK_AGENT`/`GROK_SESSION_ID` env (a native Grok session invoking this
       script directly), or a Grok-shaped payload (`sessionId`/`toolName`/
       `workspaceRoot` — the fields grok-hook-adapter.sh preserves alongside
       the Claude-shaped aliases it adds).
    3. Default to `claude` — covers native Claude Code sessions and Codex's
       apply_patch payloads, which are Claude-Code-shaped and rely on step 1's
       explicit `AGENT_RULES_AGENT=codex` hook wiring to be recognized as codex.
    """
    explicit = os.environ.get("AGENT_RULES_AGENT", "").strip().lower()
    if explicit:
        if explicit in SUPPORTED_AGENTS:
            return explicit
        print(
            f"inject-rules: unsupported AGENT_RULES_AGENT={explicit!r}; defaulting to {DEFAULT_AGENT}",
            file=sys.stderr,
        )
        return DEFAULT_AGENT

    if os.environ.get("GROK_AGENT") or os.environ.get("GROK_SESSION_ID"):
        return AGENT_GROK
    if "sessionId" in payload or "toolName" in payload or "workspaceRoot" in payload:
        return AGENT_GROK

    return DEFAULT_AGENT


def tool_path_candidates(tool_name: str, tool_input: dict, payload_cwd: str) -> list[PatchPath]:
    """Return path candidates represented by the current tool call."""
    file_path = tool_input.get("file_path", "")
    if file_path:
        return [PatchPath(resolve_tool_path(file_path, payload_cwd), False)]

    if tool_name == "apply_patch":
        patch_text = tool_input.get("command", "")
        return extract_apply_patch_paths(patch_text, payload_cwd)

    return []


def resolve_tool_path(raw_path: str, payload_cwd: str) -> Path:
    path = Path(raw_path)
    if not path.is_absolute():
        base = Path(payload_cwd) if payload_cwd else Path.cwd()
        path = base / path
    return path.resolve(strict=False)


def extract_apply_patch_paths(patch_text: str, payload_cwd: str) -> list[PatchPath]:
    """Extract path candidates from apply_patch envelope headers."""
    paths: list[PatchPath] = []
    for line in patch_text.splitlines():
        match = PATCH_PATH_RE.match(line)
        if not match:
            continue
        kind, raw_path = match.groups()
        if not raw_path:
            continue
        paths.append(
            PatchPath(
                resolve_tool_path(raw_path, payload_cwd),
                skip_match_content=(kind == "Add File"),
            )
        )
    return paths


def path_relative_to_repo(candidate: PatchPath, repo_root: Path) -> ToolPath | None:
    try:
        rel_path = str(candidate.path.relative_to(repo_root.resolve()))
    except ValueError:
        return None
    return ToolPath(str(candidate.path), rel_path, candidate.skip_match_content)


def match_tool_call(
    frontmatter: dict,
    tool_paths: list[ToolPath],
    command: str,
    pending_content: str = "",
    *,
    rule_name: str = "?",
    token_cache: dict | None = None,
) -> tuple[str, str] | None:
    for tool_path in tool_paths:
        matched = match_rule(
            frontmatter,
            tool_path.file_path,
            tool_path.rel_path,
            "",
            pending_content,
            rule_name=rule_name,
            skip_match_content=tool_path.skip_match_content,
        )
        if matched is not None:
            return matched

    return match_rule(
        frontmatter,
        "",
        "",
        command,
        rule_name=rule_name,
        token_cache=token_cache,
    )


def deny_strength(frontmatter: dict) -> str:
    """Return the deny strength for `deny_command:` gates: "once" or "always".

    "once" (the default) blocks the first matching command with the full rule
    body, then stands down for the session — educate, then trust. "always"
    blocks every matching command — for commands that are never right for an
    agent to issue directly (e.g. raw `git worktree remove`).
    """
    value = frontmatter.get("deny")
    if isinstance(value, str) and value.strip().lower() == "always":
        return "always"
    return "once"


def safe_search(pattern: str, text: str, *, rule_name: str) -> bool:
    """re.search that isolates one bad pattern from the rest of the rule.

    A pattern that fails to compile or raises re.error at search time is skipped
    with a single stderr warning naming the rule and pattern; callers treat it
    as a non-match so sibling patterns and rules still evaluate.
    """
    try:
        return re.search(pattern, text, re.MULTILINE) is not None
    except re.error as exc:
        print(
            f"inject-rules: rule `{rule_name}`: skipping invalid regex {pattern!r}: {exc}",
            file=sys.stderr,
        )
        return False


def match_rule(
    frontmatter: dict,
    file_path: str,
    rel_path: str,
    command: str,
    pending_content: str = "",
    rule_name: str = "?",
    token_cache: dict | None = None,
    *,
    skip_match_content: bool = False,
) -> tuple[str, str] | None:
    """Return (human-readable match reason, surface), or None if no match.

    Path-mode (Edit/Write/MultiEdit) and command-mode (Bash) are independent —
    a rule can opt into either or both. The first surface that hits wins; its
    reason labels the injected block and its surface ("path", "command", or
    "command-deny") drives the deny-once decision for dynamic-rules rules.

    Command-mode evaluation order (first hit wins):
      deny structured gates → legacy deny_command regexes →
      context structured gates → legacy match_command regexes.
    Tokenization is lazy and shared via `token_cache` when provided.
    """
    if rel_path:
        paths = frontmatter.get("paths") or []
        if paths and any(match_glob(g, rel_path) for g in paths):
            content_patterns = frontmatter.get("match_content") or []
            if content_patterns:
                if skip_match_content:
                    return f"`{rel_path}`", "path"
                try:
                    file_text = Path(file_path).read_text(errors="replace")
                except OSError:
                    file_text = ""
                haystacks = [t for t in (file_text, pending_content) if t]
                if any(
                    safe_search(pat, text, rule_name=rule_name)
                    for pat in content_patterns
                    for text in haystacks
                ):
                    return f"`{rel_path}`", "path"
            else:
                return f"`{rel_path}`", "path"

    if command:
        deny_gate = resolve_structured_gate(frontmatter, "deny", rule_name)
        context_gate = resolve_structured_gate(frontmatter, "context", rule_name)
        simple_commands: list[list[str]] | None = None

        def ensure_simple_commands() -> list[list[str]]:
            nonlocal simple_commands
            if simple_commands is not None:
                return simple_commands
            if token_cache is not None and "simple_commands" in token_cache:
                simple_commands = token_cache["simple_commands"]
                return simple_commands
            simple_commands = tokenize_command(command)
            if token_cache is not None:
                token_cache["simple_commands"] = simple_commands
            return simple_commands

        if deny_gate is not None:
            cmds, args_any, args_all = deny_gate
            if any_simple_command_matches(ensure_simple_commands(), cmds, args_any, args_all):
                return (
                    format_gate_reason(command, cmds, args_any, args_all),
                    "command-deny",
                )

        deny_patterns = frontmatter.get("deny_command") or []
        if deny_patterns and any(
            safe_search(pat, command, rule_name=rule_name) for pat in deny_patterns
        ):
            return f"command `{truncate(command, 80)}`", "command-deny"

        if context_gate is not None:
            cmds, args_any, args_all = context_gate
            if any_simple_command_matches(ensure_simple_commands(), cmds, args_any, args_all):
                return (
                    format_gate_reason(command, cmds, args_any, args_all),
                    "command",
                )

        cmd_patterns = frontmatter.get("match_command") or []
        if cmd_patterns and any(
            safe_search(pat, command, rule_name=rule_name) for pat in cmd_patterns
        ):
            return f"command `{truncate(command, 80)}`", "command"

    return None


def resolve_structured_gate(
    frontmatter: dict,
    kind: str,
    rule_name: str,
) -> tuple[list[str], list[str], list[str]] | None:
    """Return (gate_command, args_any, args_all) or None if absent/invalid.

    `kind` is "deny" or "context". Args without a command list are treated as
    an absent gate with a single stderr warning (hook false-negative posture;
    rules-check/sync fail loud separately).
    """
    if kind == "deny":
        cmd_key, any_key, all_key = (
            "deny_gate_command",
            "deny_gate_args_any",
            "deny_gate_args_all",
        )
    else:
        cmd_key, any_key, all_key = (
            "gate_command",
            "gate_args_any",
            "gate_args_all",
        )

    commands = list(frontmatter.get(cmd_key) or [])
    args_any = list(frontmatter.get(any_key) or [])
    args_all = list(frontmatter.get(all_key) or [])

    if not commands and not args_any and not args_all:
        return None
    if not commands:
        print(
            f"inject-rules: rule `{rule_name}`: {any_key}/{all_key} without "
            f"{cmd_key}; treating gate as absent",
            file=sys.stderr,
        )
        return None
    return commands, args_any, args_all


def format_gate_reason(
    command: str,
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
) -> str:
    """Human-readable match reason naming the structured gate that hit."""
    bits = list(commands)
    bits.extend(args_all)
    if args_any:
        bits.append("/".join(args_any))
    gate_desc = "+".join(bits) if bits else "?"
    return f"command `{truncate(command, 80)}` (gate: {gate_desc})"


def format_gate_short(
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
) -> str:
    """Compact gate description for --list output (no command string)."""
    bits = list(commands)
    bits.extend(args_all)
    if args_any:
        bits.append("/".join(args_any))
    return "+".join(bits) if bits else "?"


def has_structured_gates(frontmatter: dict) -> bool:
    """True when any structured gate key is present (including invalid args-only)."""
    for key in (
        "gate_command",
        "gate_args_any",
        "gate_args_all",
        "deny_gate_command",
        "deny_gate_args_any",
        "deny_gate_args_all",
    ):
        if frontmatter.get(key):
            return True
    return False


def has_deny_surface(frontmatter: dict) -> bool:
    """True when the rule can produce a command-deny match (gate or legacy)."""
    return bool(
        frontmatter.get("deny_gate_command")
        or frontmatter.get("deny_command")
        or frontmatter.get("deny_gate_args_any")
        or frontmatter.get("deny_gate_args_all")
    )


def has_context_surface(frontmatter: dict) -> bool:
    """True when the rule can produce a command context match (gate or legacy)."""
    return bool(
        frontmatter.get("gate_command")
        or frontmatter.get("match_command")
        or frontmatter.get("gate_args_any")
        or frontmatter.get("gate_args_all")
    )


def has_legacy_command_regexes(frontmatter: dict) -> bool:
    """True when legacy match_command / deny_command regexes are present."""
    return bool(frontmatter.get("match_command") or frontmatter.get("deny_command"))


def example_count(frontmatter: dict) -> int:
    """Total golden example commands across should_deny/match/not_match."""
    total = 0
    for key in ("should_deny", "should_match", "should_not_match"):
        val = frontmatter.get(key) or []
        if isinstance(val, list):
            total += len(val)
    return total


def classify_command(frontmatter: dict, command: str, *, rule_name: str = "?") -> str:
    """Classify a command against the rule via match_rule: deny | context | none."""
    matched = match_rule(frontmatter, "", "", command, rule_name=rule_name)
    if matched is None:
        return "none"
    _reason, surface = matched
    if surface == "command-deny":
        return "deny"
    if surface == "command":
        return "context"
    return "none"


def validate_rule_schema(frontmatter: dict, *, rule_name: str = "?") -> list[str]:
    """Return schema error strings for a rule's frontmatter (empty = valid).

    Fail-loud surface for rules-check and sync-agent-rules. Never called from
    main()/the hook path — the hook keeps false-negative posture for bad gates.

    Checks:
      - gate/deny_gate args without a corresponding command list
      - should_deny without a deny surface
      - should_match without a context surface
      - non-list or empty-string golden example entries
      - legacy match_command / deny_command / match_content patterns that fail re.compile
    """
    errors: list[str] = []
    label = f"rule `{rule_name}`"

    gate_cmds = frontmatter.get("gate_command") or []
    gate_any = frontmatter.get("gate_args_any") or []
    gate_all = frontmatter.get("gate_args_all") or []
    if (gate_any or gate_all) and not gate_cmds:
        errors.append(
            f"{label}: gate_args_any/gate_args_all without gate_command"
        )

    deny_cmds = frontmatter.get("deny_gate_command") or []
    deny_any = frontmatter.get("deny_gate_args_any") or []
    deny_all = frontmatter.get("deny_gate_args_all") or []
    if (deny_any or deny_all) and not deny_cmds:
        errors.append(
            f"{label}: deny_gate_args_any/deny_gate_args_all without deny_gate_command"
        )

    should_deny = frontmatter.get("should_deny")
    if should_deny:
        if not has_deny_surface(frontmatter):
            errors.append(
                f"{label}: should_deny present but no deny surface "
                f"(deny_gate_command or deny_command)"
            )

    should_match = frontmatter.get("should_match")
    if should_match:
        if not has_context_surface(frontmatter):
            errors.append(
                f"{label}: should_match present but no context surface "
                f"(gate_command or match_command)"
            )

    for key in ("should_deny", "should_match", "should_not_match"):
        val = frontmatter.get(key)
        if val is None:
            continue
        if not isinstance(val, list):
            errors.append(f"{label}: {key} must be a YAML list, got {type(val).__name__}")
            continue
        for i, item in enumerate(val):
            if not isinstance(item, str) or not item.strip():
                errors.append(
                    f"{label}: {key}[{i}] is empty or not a string"
                )

    for key in ("match_command", "deny_command", "match_content"):
        patterns = frontmatter.get(key) or []
        if not isinstance(patterns, list):
            errors.append(f"{label}: {key} must be a list")
            continue
        for pat in patterns:
            if not isinstance(pat, str):
                errors.append(f"{label}: {key} entry is not a string: {pat!r}")
                continue
            try:
                re.compile(pat)
            except re.error as exc:
                errors.append(
                    f"{label}: {key} pattern {pat!r} fails re.compile: {exc}"
                )

    return errors


def run_golden_examples(
    frontmatter: dict,
    *,
    rule_name: str = "?",
) -> list[dict]:
    """Run should_deny / should_match / should_not_match through match_rule.

    Returns a list of result dicts:
      {
        "key": "should_deny" | "should_match" | "should_not_match",
        "command": str,
        "expected": "deny" | "context" | "none",
        "actual": "deny" | "context" | "none",
        "ok": bool,
      }

    Module-level only — never called from main(). Callers: rules-check --examples
    and sync-agent-rules cmd_adopt pre-flight.
    """
    expectations = (
        ("should_deny", "deny"),
        ("should_match", "context"),
        ("should_not_match", "none"),
    )
    results: list[dict] = []
    for key, expected in expectations:
        commands = frontmatter.get(key) or []
        if not isinstance(commands, list):
            continue
        for command in commands:
            if not isinstance(command, str):
                continue
            actual = classify_command(frontmatter, command, rule_name=rule_name)
            results.append(
                {
                    "key": key,
                    "command": command,
                    "expected": expected,
                    "actual": actual,
                    "ok": actual == expected,
                }
            )
    return results


def any_simple_command_matches(
    simple_commands: list[list[str]],
    commands: list[str],
    args_any: list[str],
    args_all: list[str],
) -> bool:
    """True if any simple command's argv satisfies the structured gate."""
    for argv in simple_commands:
        if not argv:
            continue
        if not any(fnmatch.fnmatchcase(argv[0], pat) for pat in commands):
            continue
        arg_tokens = argv[1:]
        if args_any:
            if not any(
                any(fnmatch.fnmatchcase(tok, pat) for tok in arg_tokens)
                for pat in args_any
            ):
                continue
        if args_all:
            if not all(
                any(fnmatch.fnmatchcase(tok, pat) for tok in arg_tokens)
                for pat in args_all
            ):
                continue
        return True
    return False


def tokenize_command(command: str) -> list[list[str]]:
    """Convert a raw Bash command string into simple-command argv lists.

    Pipeline (false-negative posture — any failure returns []):
      1. Strip heredoc bodies (bodies are invisible to gates).
      2. Quote-aware: replace unquoted newlines with `;`.
      3. shlex (posix, punctuation_chars) for quote-aware tokenization.
      4. Split on shell operator tokens; skip redirection filenames.
      5. Drop leading reserved words (if/then/do/…), VAR= assignments, and
         wrapper commands (command/env/sudo/nohup/nice/stdbuf/time/timeout);
         basename argv[0].

    `bash -c "..."` inner strings are a single opaque token (not recursed).
    """
    try:
        text = strip_heredoc_bodies(command)
        text = normalize_unquoted_newlines(text)
        lexer = shlex.shlex(text, posix=True, punctuation_chars="();<>|&")
        lexer.whitespace_split = True
        raw_tokens = list(lexer)
        simple = split_simple_commands(raw_tokens)
        out: list[list[str]] = []
        for argv in simple:
            normalized = normalize_simple_command(argv)
            if normalized:
                out.append(normalized)
        return out
    except Exception:
        # ValueError (unbalanced quotes) and any unexpected parse error: gates
        # see nothing. Legacy raw regexes still run against the original string.
        return []


def strip_heredoc_bodies(text: str) -> str:
    """Remove heredoc body lines (keep the opener line; drop through delimiter).

    Multiple heredocs on one opener line are queued and consumed in order.
    `<<-` / `<<~` allow the closing delimiter to be indented with tabs.
    """
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        delimiters: list[tuple[str, bool]] = []
        for match in _HEREDOC_RE.finditer(line):
            dash, single, double, bare = match.group(1), match.group(2), match.group(3), match.group(4)
            delim = single if single is not None else double if double is not None else bare
            if not delim:
                continue
            strip_tabs = dash in ("-", "~")
            delimiters.append((delim, strip_tabs))
        out.append(line)
        i += 1
        for delim, strip_tabs in delimiters:
            while i < len(lines):
                body = lines[i]
                i += 1
                check = body.lstrip("\t") if strip_tabs else body
                if check == delim:
                    break
                # body line dropped
    return "\n".join(out)


def normalize_unquoted_newlines(text: str) -> str:
    """Replace unquoted newlines with `;` so multi-line scripts split.

    Tracks single quotes, double quotes, and backslash escapes (outside
    single quotes). Quoted multi-line strings stay intact as one token.
    """
    result: list[str] = []
    in_single = False
    in_double = False
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "\\" and not in_single and i + 1 < n:
            result.append(c)
            result.append(text[i + 1])
            i += 2
            continue
        if c == "'" and not in_double:
            in_single = not in_single
            result.append(c)
        elif c == '"' and not in_single:
            in_double = not in_double
            result.append(c)
        elif c == "\n" and not in_single and not in_double:
            result.append(";")
        else:
            result.append(c)
        i += 1
    return "".join(result)


def split_simple_commands(tokens: list[str]) -> list[list[str]]:
    """Split shlex tokens on shell operators; skip redirection filenames."""
    commands: list[list[str]] = []
    current: list[str] = []
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok and all(c in _OPERATOR_CHARS for c in tok):
            if current:
                commands.append(current)
                current = []
            i += 1
            continue
        if tok in _REDIRECT_OPS:
            i += 1
            if i < len(tokens):
                i += 1  # skip filename
            continue
        current.append(tok)
        i += 1
    if current:
        commands.append(current)
    return commands


def normalize_simple_command(argv: list[str]) -> list[str]:
    """Drop reserved-word/VAR=/wrapper prefixes; basename the effective argv[0].

    Reserved words are stripped only here — at command position — so `then git
    worktree remove x` gates on `git` while `echo do it` keeps `do` as an
    argument. Wrapper flags in `_WRAPPER_VALUE_FLAGS` consume their
    space-separated value; `timeout` additionally consumes its duration
    positional so the wrapped command lands at argv[0].
    """
    argv = list(argv)
    while True:
        while argv and argv[0] in _RESERVED_WORDS:
            argv.pop(0)
        while argv and _VAR_ASSIGN_RE.match(argv[0]):
            argv.pop(0)
        if not argv:
            return []
        head = os.path.basename(argv[0])
        if head not in _WRAPPER_COMMANDS:
            break
        wrapper = head
        argv.pop(0)
        value_flags = _WRAPPER_VALUE_FLAGS.get(wrapper, frozenset())
        while argv and argv[0].startswith("-"):
            flag = argv.pop(0)
            if flag in value_flags and argv:
                argv.pop(0)
        if wrapper == "env":
            while argv and _VAR_ASSIGN_RE.match(argv[0]):
                argv.pop(0)
        if wrapper == "timeout" and argv:
            argv.pop(0)
    if not argv:
        return []
    return [os.path.basename(argv[0]), *argv[1:]]


def normalize_tool_name(tool_name: str) -> str:
    """Map Grok tool names to the Claude names used by rule frontmatter."""
    return {
        "run_terminal_command": "Bash",
        "search_replace": "Edit",
        "write": "Write",
        "write_file": "Write",
        "skill": "Skill",
    }.get(tool_name, tool_name)


def truncate(text: str, limit: int) -> str:
    text = text.replace("\n", " ")
    if len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def find_repo_root(start: Path) -> Path | None:
    """Walk up from `start` looking for a .git directory or file."""
    current = start.resolve() if start.exists() else Path.cwd().resolve()
    while True:
        if (current / ".git").exists():
            return current
        if current.parent == current:
            return None
        current = current.parent


def cache_root() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    base = Path(xdg) if xdg else Path.home() / ".cache"
    return base / "agent-rules"


def sanitize_id(value: str) -> str:
    """Constrain session id to filename-safe characters."""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", value)[:128] or "unknown"


def repo_marker(repo_root: Path) -> str:
    """Filesystem-safe per-repo discriminator for the marker path.

    Without this, the per-session dedup key is only the rule name, so a session
    that touches two repos which both adopted a same-named central rule injects
    the rule for the first repo and silently suppresses it for the second. A
    short sha256 of the resolved repo root scopes markers per repo without
    leaking the path itself into the cache layout.
    """
    digest = hashlib.sha256(str(repo_root.resolve()).encode("utf-8")).hexdigest()
    return digest[:16]


class FrontmatterError(Exception):
    pass


def find_frontmatter_start(text: str) -> int | None:
    """Return the index of the opening `---` of a YAML frontmatter block, or None.

    Accepts any mix of leading HTML comment lines and blank lines before the
    opening fence (the agentic-worktree-mcp generator's
    `<!-- comment -->\\n\\n---` header style). Anything else means there is no
    frontmatter.
    """
    idx = 0
    while True:
        if text.startswith("---\n", idx):
            return idx
        line_end = text.find("\n", idx)
        if line_end == -1:
            return None
        line = text[idx:line_end].strip()
        if not line:
            # Blank line between provenance comment and fence — keep scanning.
            idx = line_end + 1
            continue
        if not line.startswith("<!--") or not line.endswith("-->"):
            return None
        idx = line_end + 1


def parse_frontmatter(path: Path) -> tuple[dict, str]:
    """Parse frontmatter from a rule file path. See parse_frontmatter_text."""
    return parse_frontmatter_text(path.read_text())


def parse_frontmatter_text(text: str) -> tuple[dict, str]:
    """Parse a minimal YAML frontmatter block. Supports the fields we use only:
    scalar keys plus one-level string lists (paths, gates, goldens, legacy regexes).
    Returns ({}, body) when no frontmatter is present.

    Tolerates leading provenance HTML comment lines and blank lines (e.g. the
    `<!-- agent-rules: generated vX.Y.Z -->` header sync writes) before the
    opening `---`.
    """
    start = find_frontmatter_start(text)
    if start is None:
        return {}, text
    end_idx = text.find("\n---", start + 4)
    if end_idx == -1:
        raise FrontmatterError("unterminated YAML frontmatter")

    fm_text = text[start + 4 : end_idx]
    body = text[end_idx + len("\n---") :].lstrip("\n")

    fm: dict = {
        "description": None,
        "paths": [],
        "match_content": [],
        "match_command": [],
        "deny_command": [],
        "deny": None,
        "gate_command": [],
        "gate_args_any": [],
        "gate_args_all": [],
        "deny_gate_command": [],
        "deny_gate_args_any": [],
        "deny_gate_args_all": [],
        "should_deny": [],
        "should_match": [],
        "should_not_match": [],
    }
    list_keys = {
        "paths",
        "match_content",
        "match_command",
        "deny_command",
        "gate_command",
        "gate_args_any",
        "gate_args_all",
        "deny_gate_command",
        "deny_gate_args_any",
        "deny_gate_args_all",
        "should_deny",
        "should_match",
        "should_not_match",
    }
    current_list: list | None = None

    for raw_line in fm_text.splitlines():
        line = raw_line.rstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith(" ") or line.startswith("\t"):
            stripped = line.strip()
            if current_list is None or not stripped.startswith("- "):
                continue
            value = strip_yaml_string(stripped[2:].strip())
            current_list.append(value)
            continue

        if ":" not in line:
            current_list = None
            continue
        key, _, after = line.partition(":")
        key = key.strip()
        after = after.strip()

        if key in list_keys:
            if after:
                raise FrontmatterError(f"`{key}` must be a YAML list, not inline value")
            current_list = []
            fm[key] = current_list
        elif key in ("description", "deny"):
            fm[key] = strip_yaml_string(after)
            current_list = None
        else:
            current_list = None

    return fm, body


def strip_yaml_string(value: str) -> str:
    """Strip surrounding quotes from a YAML scalar.

    Double-quoted scalars decode backslash escapes only when a backslash is
    actually present. The utf-8 → unicode_escape → latin-1 → utf-8 round-trip
    preserves non-ASCII (em dashes endemic in rule prose) while still turning
    sequences like ``\\\\b`` / ``\\\\n`` into their escaped forms — plain
    ``utf-8`` + ``unicode_escape`` alone mojibakes multi-byte UTF-8.
    """
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        inner = value[1:-1]
        if value[0] == '"' and "\\" in inner:
            inner = (
                inner.encode("utf-8")
                .decode("unicode_escape")
                .encode("latin-1")
                .decode("utf-8")
            )
        return inner
    return value


def match_glob(pattern: str, path: str) -> bool:
    """Match a gitignore-style glob against a relative path. Supports `**`."""
    regex = glob_to_regex(pattern)
    return bool(re.match(regex, path))


def glob_to_regex(pattern: str) -> str:
    """Translate a gitignore-style glob into an anchored regex.

    Semantics:
        **/  matches zero or more path components
        **   matches anything
        *    matches any character except /
        ?    matches a single character except /
    """
    out: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if i + 1 < len(pattern) and pattern[i + 1] == "*":
                if i + 2 < len(pattern) and pattern[i + 2] == "/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
            i += 1
            continue
        if c == "?":
            out.append("[^/]")
            i += 1
            continue
        if c in r".+()[]{}|^$\\":
            out.append("\\" + c)
            i += 1
            continue
        out.append(c)
        i += 1
    return "^" + "".join(out) + "$"


def format_block(rule_name: str, match_reason: str, body: str) -> str:
    """Format a rule's body for injection into Claude's additional context.

    `match_reason` is rendered verbatim after "matched " — callers wrap path
    matches as `path`-style code spans and command matches with the literal
    word "command".
    """
    header = f"### Rule: {rule_name}\n_Auto-loaded — matched {match_reason}._\n"
    return header + "\n" + body.rstrip() + "\n"


if __name__ == "__main__":
    sys.exit(main())
