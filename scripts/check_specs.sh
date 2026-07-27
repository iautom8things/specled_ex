#!/usr/bin/env bash
set -euo pipefail

ROOT="${SPEC_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$ROOT"

export MIX_ENV="${MIX_ENV:-test}"

# Arm the forensic capture unless the caller already chose a location (CI points
# it at the runner temp dir it uploads as an artifact). A failing or timed-out
# verification command persists its full output there — findings truncate that
# output and drop it entirely on timeout, so an unarmed gate run that reddens
# once and never reproduces leaves nothing to diagnose.
export SPECLED_COMMAND_OUTPUT_DIR="${SPECLED_COMMAND_OUTPUT_DIR:-$ROOT/tmp/specled-command-output}"

mix spec.check "$@"
