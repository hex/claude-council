#!/bin/bash
# ABOUTME: Queries the Kimi (Moonshot AI) API with a prompt via its OpenAI-compatible endpoint
# ABOUTME: Adds a non-US-lab voice to the council to widen the range of opinions

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
# A large prompt (e.g. a big --file) arrives via a temp file to stay off
# the process argv, where the OS would reject it as "argument list too long". The
# path is kept, not just the text: jq reads the prompt with --rawfile, so it
# stays off jq\'s argv too — bounded by the same limit.
PROMPT_FILE=""
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT_FILE="${2:?--prompt-file requires a path}"
    PROMPT=$(cat "$PROMPT_FILE")
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
# Which ids answer depends on the account: Moonshot closed the moonshot-v1
# series and kimi-k2.5 to new registrations ahead of a 2026-08-31 sunset, so a
# key issued since then gets 404 for ids the docs still list. `GET /v1/models`
# on your own key is the only authoritative answer; a list here would be right
# for whoever wrote it and wrong for the next reader.
MODEL="$(get_model kimi)"

# Kimi Open Platform endpoint (OpenAI-compatible Chat Completions)
ENDPOINT="${KIMI_ENDPOINT:-https://api.moonshot.ai/v1/chat/completions}"

# Token limit (override via COUNCIL_MAX_TOKENS env var). The K-series are
# reasoning models whose visible thinking shares the output budget, so raise
# the cap for them to avoid truncating the answer mid-sentence.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" 'kimi-k*'

# System instruction
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

# A prompt given literally as $1 is staged into a file of our own, so the
# --rawfile read below has a path either way. OWNED_PROMPT_FILE is what the trap
# removes: the orchestrator's file is not ours to delete.
OWNED_PROMPT_FILE=""
if [[ -z "$PROMPT_FILE" ]]; then
    OWNED_PROMPT_FILE=$(mktemp)
    PROMPT_FILE="$OWNED_PROMPT_FILE"
    printf '%s' "$PROMPT" > "$PROMPT_FILE"
fi

# The user-message content embeds the prompt, so it reaches the payload build
# through a file as well: --argjson would put the whole prompt back on argv.
CONTENT_FILE=$(mktemp)

# The user message content is either a bare prompt string or, when an image is
# supplied, an OpenAI-shaped [text, image_url] array. Kimi documents multimodal
# content in the same shape, but provider_vision_capable deliberately leaves
# kimi out: only the moonshot-v1-*-vision-preview ids are documented as vision
# models, and that was never verified against the live API here. The branch is
# kept so enabling vision is a one-line change in providers.sh once confirmed.
if [[ -n "$IMAGE_FILE" ]]; then
    jq -n --rawfile prompt "$PROMPT_FILE" --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" '[
        { type: "text",      text: $prompt },
        { type: "image_url", image_url: { url: ("data:" + $mime + ";base64," + $b64) } }
    ]' > "$CONTENT_FILE"
else
    jq -n --rawfile prompt "$PROMPT_FILE" '$prompt' > "$CONTENT_FILE"
fi

# max_tokens is still accepted alongside the newer max_completion_tokens, and is
# what every other provider here sends — keep the payload uniform.
PAYLOAD=$(jq -n \
    --arg model "$MODEL" \
    --argjson tokens "$TOKENS" \
    --arg system "$SYSTEM" \
    --slurpfile content "$CONTENT_FILE" \
    '{
        model: $model,
        messages: [{
            role: "system",
            content: $system
        }, {
            role: "user",
            content: $content[0]
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
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE" "$OWNED_PROMPT_FILE" "$CONTENT_FILE"' EXIT
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

    # Whitespace-stripped, not just empty: a model that answers with a single
    # space passes a bare -z test, and the council would store that as a
    # successful answer and weigh it in the synthesis like any other.
if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from Kimi: $ERROR" >&2
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
