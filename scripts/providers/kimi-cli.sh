#!/bin/bash
# ABOUTME: Queries the Kimi Code CLI in headless mode using subscription auth
# ABOUTME: Availability is gated on the kimi binary being on PATH, not an API key

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

if ! command -v kimi >/dev/null 2>&1; then
    echo "Error: kimi CLI not found on PATH" >&2
    exit 1
fi

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"
FULL_PROMPT="${SYSTEM}

${PROMPT}"

# --output-format stream-json, not the default text: the text renderer prefixes
# every line with "• ", interleaves the model's visible reasoning with the
# answer, and appends a "To resume this session: …" footer. All three would end
# up quoted verbatim in the council's synthesis. The JSONL stream separates them
# cleanly — role "assistant" is the answer, role "meta" is the session hint.
ARGS=(-p "$FULL_PROMPT" --output-format stream-json)
# -m only on an explicit override, so an unset KIMI_CLI_MODEL defers to the
# CLI's own default_model in config.toml (mirrors codex.sh and grok-cli.sh).
[[ -n "${KIMI_CLI_MODEL:-}" ]] && ARGS+=(-m "$KIMI_CLI_MODEL")

# Bound the CLI the way API providers are bounded by curl --max-time. GNU
# `timeout` is absent on stock macOS, so use perl's alarm (perl is already a
# renderer dependency); the pending alarm survives exec and kills the CLI after
# COUNCIL_TIMEOUT seconds, surfacing as exit 142 (128 + SIGALRM).
COUNCIL_TIMEOUT="${COUNCIL_TIMEOUT:-300}"

ERR_TMP=$(mktemp)
OUT_TMP=$(mktemp)
trap 'rm -f "$ERR_TMP" "$OUT_TMP"' EXIT

if perl -e 'alarm shift; exec @ARGV' "$COUNCIL_TIMEOUT" kimi "${ARGS[@]}" >"$OUT_TMP" 2>"$ERR_TMP"; then
    # Concatenate every assistant chunk; a long answer may arrive in several.
    # Non-JSON lines are skipped rather than aborting the run: the CLI is free
    # to print an unstructured warning alongside the stream.
    RESPONSE=$(jq -rs 'map(select(type == "object" and .role == "assistant") | .content // empty) | join("")' "$OUT_TMP" 2>/dev/null || true)
    if [[ -z "${RESPONSE//[[:space:]]/}" ]]; then
        echo "Error from kimi CLI: no assistant content in response" >&2
        exit 1
    fi
    echo "$RESPONSE"
else
    rc=$?
    if [[ $rc -eq 142 ]]; then
        echo "Error from kimi CLI: timed out after ${COUNCIL_TIMEOUT}s" >&2
    else
        ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | head -c 500)
        echo "Error from kimi CLI: ${ERR_MSG:-non-zero exit}" >&2
    fi
    exit 1
fi
