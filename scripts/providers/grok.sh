#!/bin/bash
# ABOUTME: Queries xAI Grok API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

# Source shared libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"
source "$SCRIPT_DIR/../lib/keys.sh"
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

resolve_grok_key
API_KEY="${GROK_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: XAI_API_KEY (or GROK_API_KEY) not set" >&2
    exit 1
fi

# xAI API endpoint (OpenAI-compatible)
ENDPOINT="https://api.x.ai/v1/chat/completions"

# Model selection (override via GROK_MODEL env var). get_model owns the default
# so the id sent here is the one the orchestrator labels and caches by.
MODEL="$(get_model grok)"

# Token limit (override via COUNCIL_MAX_TOKENS env var). Reasoning models need a
# higher cap; for grok-build max_tokens caps visible output only (thinking
# uncapped), else the two share it. The alias is matched literally rather than as
# '*-latest': xAI publishes non-reasoning aliases too (grok-4.20-non-reasoning-latest),
# whose whole budget is visible output, and raising the cap on those would override
# a COUNCIL_MAX_TOKENS the user set deliberately.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" '*reasoning*' 'grok-4*' 'grok-3-mini-*' 'grok-build-*' 'grok-latest'

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

# Build request payload
if [[ -n "$IMAGE_FILE" ]]; then
    PAYLOAD=$(jq -n --rawfile prompt "$PROMPT_FILE" --arg model "$MODEL" --argjson tokens "$TOKENS" --arg system "$SYSTEM" \
        --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" '{
        model: $model,
        messages: [
            { role: "system", content: $system },
            { role: "user", content: [
                { type: "text",      text: $prompt },
                { type: "image_url", image_url: { url: ("data:" + $mime + ";base64," + $b64) } }
            ]}
        ],
        temperature: 0.7,
        max_tokens: $tokens
    }')
else
    PAYLOAD=$(jq -n --rawfile prompt "$PROMPT_FILE" --arg model "$MODEL" --argjson tokens "$TOKENS" --arg system "$SYSTEM" '{
        model: $model,
        messages: [{
            role: "system",
            content: $system
        }, {
            role: "user",
            content: $prompt
        }],
        temperature: 0.7,
        max_tokens: $tokens
    }')
fi

# Keep the API key and request body off the process argv (ps-visible / OS
# argument-size limits): the key travels via a mode-600 curl config file and
# the payload via a temp file.
CURL_CFG=$(curl_secret_config "Authorization: Bearer ${API_KEY}")
PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE" "$OWNED_PROMPT_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    --config "$CURL_CFG" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

# Extract text from response
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from Grok: $ERROR" >&2
    # Exit 3 tells query-council.sh this model is unavailable for this key or
    # region, and that the fallback model is worth trying.
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
