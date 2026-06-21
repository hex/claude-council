#!/bin/bash
# ABOUTME: Queries Google's Antigravity CLI (agy) in print mode using subscription auth
# ABOUTME: Availability is gated on the agy binary being on PATH, not an API key

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

if ! command -v agy >/dev/null 2>&1; then
    echo "Error: agy CLI not found on PATH" >&2
    exit 1
fi

# agy is an agentic coding assistant, not a chat CLI: left unconstrained it
# answers by writing a report artifact to disk and returning a pointer to it.
# This guard makes it answer inline as plain text with no tool use — the only
# effective control, since agy exposes no flag to disable tools or set output.
GUARD="IMPORTANT: Respond with your complete answer as plain text directly in this conversation. Do NOT use any tools. Do NOT write, create, or edit any files. Do NOT create artifacts, reports, or documents. Do NOT reference external files. Provide your entire response inline as text."

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${GUARD}

${SYSTEM}

${PROMPT}"

MODEL=$(get_model antigravity)
# Flags must precede the prompt: agy uses Go's flag package, which stops
# parsing at the first positional argument, so flags after the prompt get
# folded into the prompt text. --sandbox restricts terminal access as
# defense-in-depth alongside the guard.
ARGS=(--sandbox --model "$MODEL" -p "$FULL_PROMPT")

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(agy "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
    echo "Error from antigravity CLI: ${ERR_MSG:-non-zero exit}" >&2
    exit 1
fi
