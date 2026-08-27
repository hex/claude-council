#!/bin/bash
# ABOUTME: Queries Google Gemini API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"
source "$SCRIPT_DIR/../lib/tokens.sh"
source "$SCRIPT_DIR/../lib/verbosity.sh"
source "$SCRIPT_DIR/../lib/providers.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

# Debug mode
DEBUG="${COUNCIL_DEBUG:-}"

PROMPT="${1:-}"
IMAGE_FILE=""
IMAGE_MIME=""
# A large prompt (e.g. a big --file) arrives via a temp file to stay off the
# process argv, where the OS would reject it as "argument list too long".
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT=$(cat "${2:?--prompt-file requires a path}")
    shift 2
elif [[ $# -gt 0 ]]; then
    shift
fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image-file) IMAGE_FILE="${2:?--image-file requires a path}"; shift 2 ;;
        --image-mime) IMAGE_MIME="${2:?--image-mime requires a value}"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${GEMINI_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: GEMINI_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via GEMINI_MODEL env var). get_model owns the
# default so the id sent here is the one the orchestrator labels and caches by.
MODEL="$(get_model gemini)"

# Gemini API endpoint
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

# Token limit (override via COUNCIL_MAX_TOKENS env var). Reasoning models need a
# much higher cap since maxOutputTokens combines reasoning + output. Google's
# -latest aliases all serve models that think, so the alias pattern is scoped to
# them rather than left as a bare '*-latest' that would also raise a deliberate
# COUNCIL_MAX_TOKENS on some future non-reasoning alias.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" 'gemini-3*' '*thinking*' 'gemini-*-latest'

SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

# Cap on internal "thinking" tokens (override via GEMINI_THINKING_BUDGET). A
# reasoning model can otherwise burn the entire maxOutputTokens allowance on
# invisible chain-of-thought and return an empty answer with no error field —
# capping thinking guarantees room is left for the actual response, and tends
# to cut the tail latency that causes request timeouts too.
THINKING_BUDGET="${GEMINI_THINKING_BUDGET:-8192}"

# Build request payload
if [[ -n "$IMAGE_FILE" ]]; then
    PAYLOAD=$(jq -n --arg prompt "$PROMPT" --argjson tokens "$TOKENS" --arg system "$SYSTEM" \
        --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" --argjson thinking "$THINKING_BUDGET" '{
        system_instruction: { parts: [{ text: $system }] },
        contents: [{ parts: [
            { text: $prompt },
            { inlineData: { mimeType: $mime, data: $b64 } }
        ]}],
        generationConfig: { temperature: 0.7, maxOutputTokens: $tokens, thinkingConfig: { thinkingBudget: $thinking } }
    }')
else
    PAYLOAD=$(jq -n --arg prompt "$PROMPT" --argjson tokens "$TOKENS" --arg system "$SYSTEM" --argjson thinking "$THINKING_BUDGET" '{
        system_instruction: { parts: [{ text: $system }] },
        contents: [{ parts: [{ text: $prompt }] }],
        generationConfig: { temperature: 0.7, maxOutputTokens: $tokens, thinkingConfig: { thinkingBudget: $thinking } }
    }')
fi

# Keep the API key and request body off the process argv (ps-visible, and the
# key would otherwise sit in the URL query string): the key travels via a
# mode-600 curl config file (x-goog-api-key header) and the payload via a file.
CURL_CFG=$(curl_secret_config "x-goog-api-key: ${API_KEY}")
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    --config "$CURL_CFG" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

# Extract text from response. Join every text part rather than assuming the
# answer sits in parts[0] — a thought-signature part can precede it.
TEXT=$(echo "$RESPONSE" | jq -r '[.candidates[0].content.parts[]? | select(.text) | .text] | join("") // empty')

if [[ -z "$TEXT" ]]; then
    # A well-formed HTTP error carries .error.message. A 200 with no visible
    # text (most often the model spending its whole token budget on internal
    # reasoning, or a safety block) carries neither .error nor .candidates —
    # surface finishReason/blockReason/token usage instead of a bare
    # "Unknown error" so the real cause is visible in logs.
    ERROR=$(echo "$RESPONSE" | jq -r '
        if (.error.message // "") != "" then .error.message
        elif (.promptFeedback.blockReason // "") != "" then
            "prompt blocked (" + .promptFeedback.blockReason + ")"
        elif (.candidates[0].finishReason // "") != "" then
            "empty response (finishReason: " + .candidates[0].finishReason +
            ", thoughts tokens: " + ((.usageMetadata.thoughtsTokenCount // 0) | tostring) +
            "/" + ((.usageMetadata.totalTokenCount // 0) | tostring) + ")"
        else "Unknown error" end')
    echo "Error from Gemini: $ERROR" >&2
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
