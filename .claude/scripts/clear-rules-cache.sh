#!/usr/bin/env bash
# agent-rules: generated v0.3.0
# SessionEnd/SessionStart hook: prune rule-injection marker directories.
#
# Reads the hook payload from stdin (JSON), extracts session_id/sessionId, and
# removes ${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/<agent>/<session_id>/.
# Grok headless sessions do not reliably fire SessionEnd, so Grok also prunes
# old session directories on SessionStart.
#
# Claude and Codex no longer register this as their primary cache-cleanup
# hook — the age-based `prune-rules-cache` SessionStart hook owns that job for
# both. This script stays installed so repos with an older, not-yet-resynced
# SessionEnd registration keep working exactly as before.

set -euo pipefail

input="$(cat || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)"
event_name="$(printf '%s' "$input" | jq -r '.hook_event_name // .hookEventName // empty' 2>/dev/null || true)"
agent="${AGENT_RULES_AGENT:-}"

if [ -z "$agent" ]; then
  if [ -n "${GROK_AGENT:-}" ] || [ -n "${GROK_SESSION_ID:-}" ]; then
    agent="grok"
  else
    agent="claude"
  fi
fi

case "$agent" in
  claude|codex|grok) ;;
  *) agent="claude" ;;
esac

cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/agent-rules/$agent"

# Restrict to filename-safe characters so we never traverse out of cache_root.
clean_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128)"

case "$event_name" in
  SessionStart|session_start|new|resume)
    if [ "$agent" = "grok" ] && [ -d "$cache_root" ]; then
      find "$cache_root" -mindepth 1 -maxdepth 1 -type d ! -name "$clean_id" -exec rm -rf -- {} +
    fi
    ;;
  *)
    [ -n "$clean_id" ] || exit 0
    session_dir="$cache_root/$clean_id"
    case "$session_dir" in
      "$cache_root"/*) rm -rf -- "$session_dir" ;;
    esac
    ;;
esac

exit 0
