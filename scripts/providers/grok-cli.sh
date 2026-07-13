#!/bin/bash
# ABOUTME: Queries the xAI Grok CLI in headless single-turn mode using subscription auth
# ABOUTME: Availability is gated on the grok binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

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

if ! command -v grok >/dev/null 2>&1; then
    echo "Error: grok CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

MODEL=$(get_model grok-cli)
# -p: single-turn prompt — grok prints the answer to stdout and exits, no TUI.
# --output-format plain: bare text, so the response needs no JSON unwrapping.
# --sandbox read-only: the council only reads stdout, so pin grok's built-in
# read-only profile rather than inherit a permissive user config — a defense
# against model-generated file writes or shell from an adversarial prompt
# (mirrors codex's -s read-only and agy's --sandbox guard).
ARGS=(-p "$FULL_PROMPT" --output-format plain -m "$MODEL" --sandbox read-only)

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" grok "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 142 ]]; then
        echo "Error from grok CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from grok CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
