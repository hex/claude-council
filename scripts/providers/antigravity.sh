#!/bin/bash
# ABOUTME: Queries Google's Antigravity CLI (agy) in print mode using subscription auth
# ABOUTME: Availability is gated on the agy binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

PROMPT="${1:-}"
# A large prompt (e.g. a big --file) arrives via a temp file to stay off
# the process argv, where the OS would reject it as "argument list too long".
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT=$(cat "${2:?--prompt-file requires a path}")
fi

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
    echo "Error: agy CLI not found on PATH" >&2
    exit 1
fi

# agy answers by writing a report artifact to disk unless pinned inline —
# see INLINE_ANSWER_GUARD in lib/verbosity.sh.
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${INLINE_ANSWER_GUARD}

${SYSTEM}

${PROMPT}"

# Flags must precede the prompt: agy uses Go's flag package, which stops
# parsing at the first positional argument, so flags after the prompt get
# folded into the prompt text. --sandbox restricts terminal access as
# defense-in-depth alongside the guard.
ARGS=(--sandbox)
# --model only on an explicit override: a pinned label would override the
# model selected in the Antigravity app, so an unset ANTIGRAVITY_MODEL defers
# to agy's own selection (mirrors codex.sh and grok-cli.sh).
[[ -n "${ANTIGRAVITY_MODEL:-}" ]] && ARGS+=(--model "$ANTIGRAVITY_MODEL")
ARGS+=(-p "$FULL_PROMPT")

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" agy "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 142 ]]; then
        echo "Error from antigravity CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from antigravity CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
