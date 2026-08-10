#!/bin/bash
# ABOUTME: Queries the Kimi (Moonshot AI) API with a prompt via its OpenAI-compatible endpoint
# ABOUTME: Adds a non-US-lab voice to the council to widen the range of opinions

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"
source "$SCRIPT_DIR/../lib/tokens.sh"
source "$SCRIPT_DIR/../lib/verbosity.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

# Debug mode
DEBUG="${COUNCIL_DEBUG:-}"

PROMPT="${1:-}"
IMAGE_FILE=""
IMAGE_MIME=""
# A large prompt (e.g. a big --file) arrives via a temp file to stay off
# the process argv, where the OS would reject it as "argument list too long".
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

# Check for API key. Named KIMI_API_KEY because discover_providers derives the
# variable from this file's name; MOONSHOT_API_KEY is accepted as an alias for
# anyone who already exports Moonshot's own convention, but only KIMI_API_KEY
# makes the provider discoverable.
API_KEY="${KIMI_API_KEY:-${MOONSHOT_API_KEY:-}}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: KIMI_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via KIMI_MODEL env var)
# Available: kimi-k3, kimi-k2.7-code, kimi-k2.7-code-highspeed, kimi-k2.6,
# kimi-k2.5, moonshot-v1-{8k,32k,128k,auto} and the -vision-preview variants.
MODEL="${KIMI_MODEL:-kimi-k3}"

# Kimi Open Platform endpoint (OpenAI-compatible Chat Completions)
ENDPOINT="${KIMI_ENDPOINT:-https://api.moonshot.ai/v1/chat/completions}"

# Token limit (override via COUNCIL_MAX_TOKENS env var). The K-series are
# reasoning models whose visible thinking shares the output budget, so raise
# the cap for them to avoid truncating the answer mid-sentence.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" 'kimi-k*'

# System instruction
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

# The user message content is either a bare prompt string or, when an image is
# supplied, an OpenAI-shaped [text, image_url] array. Kimi documents multimodal
# content in the same shape, but provider_vision_capable deliberately leaves
# kimi out: only the moonshot-v1-*-vision-preview ids are documented as vision
# models, and that was never verified against the live API here. The branch is
# kept so enabling vision is a one-line change in providers.sh once confirmed.
if [[ -n "$IMAGE_FILE" ]]; then
    USER_CONTENT=$(jq -n --arg prompt "$PROMPT" --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" '[
        { type: "text",      text: $prompt },
        { type: "image_url", image_url: { url: ("data:" + $mime + ";base64," + $b64) } }
    ]')
else
    USER_CONTENT=$(jq -n --arg prompt "$PROMPT" '$prompt')
fi

# max_tokens is still accepted alongside the newer max_completion_tokens, and is
# what every other provider here sends — keep the payload uniform.
PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --argjson tokens "$TOKENS" \
    --arg system "$SYSTEM" \
    --argjson content "$USER_CONTENT" \
    '{
        model: $model,
        messages: [{
            role: "system",
            content: $system
        }, {
            role: "user",
            content: $content
        }],
        # Moonshot rejects every value but 1 across its whole model line, with
        # "invalid temperature: only 1 is allowed for this model". The 0.7 the
        # other API providers send fails the request outright rather than
        # degrading, so this is the only value the endpoint accepts.
        temperature: 1,
        max_tokens: $tokens
    }')

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Kimi ===" >&2
    echo "Model: $MODEL" >&2
    echo "Endpoint: $ENDPOINT" >&2
    echo "Max tokens: $TOKENS" >&2
fi

# Keep the API key and request body off the process argv (ps-visible / OS
# argument-size limits): the key travels via a mode-600 curl config file and
# the payload via a temp file.
CURL_CFG=$(curl_secret_config "Authorization: Bearer ${API_KEY}")
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    --config "$CURL_CFG" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Response metadata ===" >&2
    echo "$RESPONSE" | jq '{ model: .model, usage: .usage }' >&2 2>/dev/null || true
fi

# Extract text from response (OpenAI-compatible format)
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from Kimi: $ERROR" >&2
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
