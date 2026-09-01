#!/bin/bash
# ABOUTME: Queries the OpenRouter API, a router fronting many vendors' models
# ABOUTME: Sends exactly one model id so the seat's identity survives the routing

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
# stays off jq's argv too — bounded by the same limit.
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

# Check for API key
API_KEY="${OPENROUTER_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: OPENROUTER_API_KEY not set" >&2
    exit 1
fi

# Which seat this run is. A roster (OPENROUTER_MODELS) turns this one script
# into openrouter-1..N, and the orchestrator names the seat it is running so the
# model comes from the seat rather than the script — otherwise every seat would
# post the same default while its header claimed the roster entry.
# Only a name this script can actually be is honoured: COUNCIL_SEAT is
# orchestrator state, and a stale value in a user's shell must not silently
# retarget a direct invocation.
SEAT="openrouter"
case "${COUNCIL_SEAT:-}" in
    openrouter|openrouter-[0-9]*) SEAT="$COUNCIL_SEAT" ;;
esac

# Model selection (override via OPENROUTER_MODEL, or <SEAT>_MODEL for a roster
# seat). Exactly one id is sent: OpenRouter may fail over among upstreams serving
# that same id, which preserves identity, but `models[]` or `route: "fallback"`
# would let it answer as a different model than the one the council labels,
# caches and synthesizes.
MODEL="$(get_model "$SEAT")"

# OpenRouter API endpoint (OpenAI-compatible)
ENDPOINT="https://openrouter.ai/api/v1/chat/completions"

# Token limit (override via COUNCIL_MAX_TOKENS env var). The seat is
# retargetable, so the reasoning bump keys off the id's shape rather than a
# fixed model list: a routed reasoning model shares its budget between hidden
# thinking and visible output and would otherwise truncate mid-answer.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-2048}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" '*reasoning*' '*thinking*'

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

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: OpenRouter ===" >&2
    echo "Model: $MODEL" >&2
    echo "Max tokens: $TOKENS" >&2
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

# The id the router actually served is reported in .model and the upstream
# vendor in .provider, both of which can differ from the id we asked for. It is
# logged only under COUNCIL_DEBUG: run_provider_script merges this stream into
# stdout, and on the success path the whole capture becomes the council's
# answer, so an unconditional line here would pollute it.
if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Response metadata ===" >&2
    echo "$RESPONSE" | jq '{
        model: .model,
        provider: .provider,
        usage: .usage
    }' >&2 2>/dev/null || true
fi

# Extract text from response (OpenAI-compatible format)
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

    # Whitespace-stripped, not just empty: a model that answers with a single
    # space passes a bare -z test, and the council would store that as a
    # successful answer and weigh it in the synthesis like any other.
if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    # .error is an object here and a bare string for some vendors; indexing a
    # string raises in jq rather than yielding null, and `//` does not catch a
    # raise, so both reads below branch on the type first.
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from OpenRouter: $ERROR" >&2

    # OpenRouter can answer HTTP 200 with an error object and no .choices, so
    # .error.code is the effective status and the wire code stamped by
    # ensure_error_body is only the fallback. is_model_unavailable_error cannot
    # serve here: it reads .http_status alone (absent on the 200 path) and maps
    # 403 to exit 3, while OpenRouter uses 403 for a moderation-flagged prompt
    # that a different model would refuse just as fast.
    # Only a numeric .error.code counts: `//` falls through on null, not on a
    # non-empty string, so an upstream passthrough code like "model_not_found"
    # would shadow the wire status ensure_error_body stamped.
    CODE=$(echo "$RESPONSE" | jq -r '
        ((if (.error | type) == "object" and (.error.code | type) == "number"
          then .error.code else null end) // .http_status // empty)' 2>/dev/null || true)
    if [[ "$CODE" == "402" ]]; then
        echo "Out of credits - top up at https://openrouter.ai/credits" >&2
    fi

    # exit 3 means "a different model would help, and it is safe to remember
    # that for 24 hours". 401 and 402 are key and wallet faults a fallback
    # shares, and 429/5xx are transient, so none of those qualify.
    case "$CODE" in
        # "No endpoints found for <id>" — the id is real but nothing serves it.
        404) exit 3 ;;
        # An unknown slug comes back 400, not 404 (verified against the live
        # API). 400 also covers ordinary bad parameters, which are malformed
        # whichever model receives them, so only a message saying the model id
        # itself is invalid is a model verdict.
        400)
            case "$(printf '%s' "$ERROR" | tr '[:upper:]' '[:lower:]')" in
                *"not a valid model"*|*"model not found"*|*"invalid model"*) exit 3 ;;
            esac
            ;;
    esac
    exit 1
fi

echo "$TEXT"
