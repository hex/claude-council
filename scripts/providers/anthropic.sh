#!/bin/bash
# ABOUTME: Queries Anthropic Messages API with extended thinking
# ABOUTME: Returns the model's response text to stdout

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"
source "$SCRIPT_DIR/../lib/verbosity.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

# Debug mode: set COUNCIL_DEBUG=1 to see request/response details
DEBUG="${COUNCIL_DEBUG:-}"

PROMPT="${1:-}"
# A large prompt (e.g. a big --file) arrives via a temp file to stay off the
# process argv, where the OS would reject it as "argument list too long".
# Matches the openai.sh / gemini.sh / grok.sh / perplexity.sh convention.
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT=$(cat "${2:?--prompt-file requires a path}")
    shift 2
elif [[ $# -gt 0 ]]; then
    shift
fi
# Consume-and-ignore any remaining flags (e.g. --image-file / --image-mime)
# so a caller written against the vision-capable providers doesn't fail on
# this text-only provider. Vision support is a deferred follow-up (see spec).
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-file|--image-mime) shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: ANTHROPIC_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via ANTHROPIC_MODEL env var).
# Default pinned to Anthropic's flagship as of 2026-07-08; re-check against
# Anthropic release notes or `claude --list-models` if a newer flagship exists.
MODEL="${ANTHROPIC_MODEL:-claude-opus-4-7}"

# Base token limit for the visible answer (override via COUNCIL_MAX_TOKENS).
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"

# Extended thinking budget. Anthropic's docs recommend ~10k for reasoning
# tasks. Kept a compile-time constant in this PR; making it env-var-tunable
# (ANTHROPIC_THINKING_EFFORT) is a deferred follow-up.
THINKING_BUDGET=10000

# max_tokens must exceed thinking.budget_tokens; splitting them additively
# preserves the visible-answer headroom when a user bumps COUNCIL_MAX_TOKENS.
MAX_TOKENS=$(( THINKING_BUDGET + BASE_TOKENS ))

ENDPOINT="https://api.anthropic.com/v1/messages"

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

PAYLOAD=$(jq -n \
    --arg prompt "$PROMPT" \
    --arg model "$MODEL" \
    --arg system "$SYSTEM" \
    --argjson thinking_budget "$THINKING_BUDGET" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{
        model: $model,
        system: $system,
        messages: [{role: "user", content: $prompt}],
        thinking: {type: "enabled", budget_tokens: $thinking_budget},
        max_tokens: $max_tokens
    }')

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Anthropic /v1/messages ===" >&2
    echo "Model: $MODEL" >&2
    echo "Max tokens: $MAX_TOKENS (thinking $THINKING_BUDGET + answer $BASE_TOKENS)" >&2
fi

# Keys travel via curl_secret_config (mode-600 config file) so they never
# appear in the process argv. Two Anthropic-required headers (auth + version)
# go through the same file.
CFG=$(curl_secret_config \
    "x-api-key: ${API_KEY}" \
    "anthropic-version: 2023-06-01")
# shellcheck disable=SC2064  # $CFG is set once and never reassigned
trap 'rm -f "$CFG"' EXIT

RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    --config "$CFG" \
    -d "$PAYLOAD")

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Response metadata ===" >&2
    echo "$RESPONSE" | jq '{
        id: .id,
        model: .model,
        stop_reason: .stop_reason,
        usage: .usage,
        content_types: [.content[]?.type]
    }' >&2
fi

# Anthropic's content is an array of typed blocks (thinking + text). Extract
# the first text block; thinking blocks are filtered out.
TEXT=$(echo "$RESPONSE" | jq -r '
    [.content[]? | select(.type == "text") | .text] | first // empty
')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // .error // empty')
    if [[ -z "$ERROR" ]]; then
        echo "Error from Anthropic: Unable to parse response" >&2
        echo "Raw response: $RESPONSE" >&2
    else
        echo "Error from Anthropic: $ERROR" >&2
    fi
    exit 1
fi

echo "$TEXT"
