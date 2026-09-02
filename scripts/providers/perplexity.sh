#!/bin/bash
# ABOUTME: Queries Perplexity API with a prompt using search-augmented models
# ABOUTME: Returns web-grounded responses with optional citation support

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
    PROMPT=""
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

if [[ -z "$PROMPT" && ! -s "$PROMPT_FILE" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${PERPLEXITY_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: PERPLEXITY_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via PERPLEXITY_MODEL env var)
# Available: sonar, sonar-pro, sonar-reasoning, sonar-reasoning-pro
MODEL="$(get_model perplexity)"

# Perplexity API endpoint (OpenAI-compatible)
ENDPOINT="https://api.perplexity.ai/chat/completions"

# Token limit (override via COUNCIL_MAX_TOKENS env var). Reasoning models
# (sonar-reasoning*, *deep-research*) emit visible <think> output that shares
# the max_tokens budget, so bump the cap to avoid mid-response truncation.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" 'sonar-reasoning*' '*deep-research*'

# Search recency filter: day, week, month, year (override via PERPLEXITY_RECENCY)
# Empty means no filter (all time)
RECENCY="${PERPLEXITY_RECENCY:-}"

# System instruction
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT When citing sources, include them inline."

# One trap for every temp file this script owns, installed before the first of
# them exists and naming them all: a failure between here and the request —
# a jq that cannot read the image file, say — would otherwise leave the prompt
# file behind, and an EXIT trap that expands a name not yet assigned ends where
# it stands under set -u without removing anything.
CURL_CFG="" PAYLOAD_FILE="" OWNED_PROMPT_FILE=""
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE" "$OWNED_PROMPT_FILE"' EXIT

stage_prompt_file

# The user-message content embeds the prompt, so it reaches the payload build
# on stdin: printf is a builtin, so neither the argv limit nor a temp file is
# involved, where --argjson would put the whole prompt back on argv.
# Build request payload
# Perplexity extends OpenAI format with search-specific parameters.
# The user message content is either a bare prompt string or, when an image is
# supplied, an OpenAI-shaped [text, image_url] array. Building it once here keeps
# the image variant orthogonal to the recency branch below (no 2x2 duplication).
if [[ -n "$IMAGE_FILE" ]]; then
    USER_CONTENT=$(jq -n --rawfile prompt "$PROMPT_FILE" --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" '[
        { type: "text",      text: $prompt },
        { type: "image_url", image_url: { url: ("data:" + $mime + ";base64," + $b64) } }
    ]')
else
    USER_CONTENT=$(jq -n --rawfile prompt "$PROMPT_FILE" '$prompt')
fi

if [[ -n "$RECENCY" ]]; then
    PAYLOAD=$(printf '%s' "$USER_CONTENT" | jq \
        --arg model "$MODEL" \
        --argjson tokens "$TOKENS" \
        --arg system "$SYSTEM" \
        --arg recency "$RECENCY" \
        '{
            model: $model,
            messages: [{
                role: "system",
                content: $system
            }, {
                role: "user",
                content: .
            }],
            temperature: 0.7,
            max_tokens: $tokens,
            return_citations: true,
            search_recency_filter: $recency
        }')
else
    PAYLOAD=$(printf '%s' "$USER_CONTENT" | jq \
        --arg model "$MODEL" \
        --argjson tokens "$TOKENS" \
        --arg system "$SYSTEM" \
        '{
            model: $model,
            messages: [{
                role: "system",
                content: $system
            }, {
                role: "user",
                content: .
            }],
            temperature: 0.7,
            max_tokens: $tokens,
            return_citations: true
        }')
fi

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Perplexity ===" >&2
    echo "Model: $MODEL" >&2
    echo "Max tokens: $TOKENS" >&2
    [[ -n "$RECENCY" ]] && echo "Recency filter: $RECENCY" >&2
fi

# Keep the API key and request body off the process argv (ps-visible / OS
# argument-size limits): the key travels via a mode-600 curl config file and
# the payload via a temp file.
CURL_CFG=$(curl_secret_config "Authorization: Bearer ${API_KEY}")
PAYLOAD_FILE=$(mktemp)
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    --config "$CURL_CFG" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Response metadata ===" >&2
    echo "$RESPONSE" | jq '{
        model: .model,
        usage: .usage,
        citations: (if .citations then (.citations | length) else 0 end)
    }' >&2 2>/dev/null || true
fi

# Extract text from response (OpenAI-compatible format)
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

    # Whitespace-stripped, not just empty: a model that answers with a single
    # space passes a bare -z test, and the council would store that as a
    # successful answer and weigh it in the synthesis like any other.
if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from Perplexity: $ERROR" >&2
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
