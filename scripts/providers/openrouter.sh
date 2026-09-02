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
router_seat_index "${COUNCIL_SEAT:-}" >/dev/null && SEAT="$COUNCIL_SEAT"

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
# The shapes the router actually serves reasoning models under, not just the two
# words: r1 and deepseek's line, the qwen line, gpt-oss, and the o-series, whose
# ids are bare enough that the pattern is anchored to the vendor slash so an
# unrelated id merely containing "o3" is not swept in. Erring toward the bump is
# the cheap direction — max_tokens is a ceiling, not a spend, while too low a
# ceiling truncates the answer mid-sentence and nothing downstream reads
# finish_reason, so the fragment caches and synthesizes as a normal success.
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" \
    '*reasoning*' '*thinking*' '*r1*' '*deepseek*' '*qwen*' '*gpt-oss*' \
    '*/o1*' '*/o3*' '*/o4*'

# System instruction
SYSTEM="${VERBOSITY_PREFIX:+$VERBOSITY_PREFIX }$BASE_SYSTEM_PROMPT"

# One trap for every temp file this script owns, installed before the first of
# them exists and naming them all: a failure between here and the request —
# a jq that cannot read the image file, say — would otherwise leave the prompt
# file behind, and an EXIT trap that expands a name not yet assigned ends where
# it stands under set -u without removing anything.
CURL_CFG="" PAYLOAD_FILE="" OWNED_PROMPT_FILE=""
trap 'rm -f "$CURL_CFG" "$PAYLOAD_FILE" "$OWNED_PROMPT_FILE"' EXIT

stage_prompt_file

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
    # Three different failures all arrive here as "no text", and only the first
    # carries a top-level .error: a wire error (>=400, given a message by
    # ensure_error_body); a mid-generation upstream failure, which OpenRouter
    # documents as an HTTP 200 whose error sits on the choice; and a clean 200
    # whose content is simply empty — a reasoning model that spent its budget
    # thinking, or an upstream that left the answer in .reasoning. Naming which
    # is the whole diagnostic value: "Unknown error" is the same word for all
    # three and points at none of them.
    #
    # An .error is an object here and a bare string for some vendors, at the top
    # level and on the choice alike; indexing a string raises in jq rather than
    # yielding null, and `//` does not catch a raise, so err_fields branches on
    # the type before it reads anything. One definition for both sites: the two
    # reads differ only in which value they start from.
    ERROR=$(echo "$RESPONSE" | jq -r '
        def err_fields:
            if type == "object" then {msg: ((.message // "") | tostring), code: (.code // null)}
            elif type == "string" then {msg: ., code: null}
            else {msg: "", code: null} end;
        (.error | err_fields) as $top
        # `?` for a .choices that is not an array, `// null` because a
        # suppressed raise yields empty rather than null and would leave the
        # whole expression — and so the error line — blank.
        | (.choices[0]? // null) as $c
        | ($c.error | err_fields) as $mid
        | if $top.msg != "" then $top.msg
          elif $mid.msg != "" then
              "provider error"
              + (if $mid.code != null then " (" + ($mid.code | tostring) + ")" else "" end)
              + ": " + $mid.msg
          elif $c != null then
              "empty response (finish_reason: " + (($c.finish_reason // "none") | tostring)
              + ", native: " + (($c.native_finish_reason // "none") | tostring)
              + ", reasoning tokens: " + ((.usage.completion_tokens_details.reasoning_tokens // 0) | tostring)
              + "/" + ((.usage.completion_tokens // 0) | tostring)
              + ", reasoning chars: " + (($c.message.reasoning // "") | tostring | length | tostring) + ")"
          else "Unknown error" end')
    echo "Error from OpenRouter: $ERROR" >&2

    # The classified line above covers the shapes we know; the raw body is the
    # catch-all for one we do not. Debug-gated because run_provider_script
    # merges this stream into the text the council stores as the seat's error.
    if [[ -n "$DEBUG" ]]; then
        echo "=== DEBUG: Raw response ===" >&2
        echo "$RESPONSE" >&2
    fi

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
        400) model_unavailable_message "$ERROR" && exit 3 ;;
    esac
    exit 1
fi

echo "$TEXT"
