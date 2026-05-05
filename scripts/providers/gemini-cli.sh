#!/bin/bash
# ABOUTME: Queries the Google Gemini CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the gemini binary being on PATH, not GEMINI_API_KEY

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

if ! command -v gemini >/dev/null 2>&1; then
    echo "Error: gemini CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# --skip-trust bypasses the trusted-folders guardrail for non-interactive use.
# The council only sends text and reads text; gemini gets no filesystem access
# from us, so the guardrail is overcautious for this code path.
MODEL=$(get_model gemini-cli)
ARGS=(--skip-trust -m "$MODEL" -p "$FULL_PROMPT")

ERR_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP"' EXIT

if RESPONSE=$(gemini "${ARGS[@]}" 2>"$ERR_TMP"); then
    echo "$RESPONSE"
else
    ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
    echo "Error from gemini CLI: ${ERR_MSG:-non-zero exit}" >&2
    exit 1
fi
