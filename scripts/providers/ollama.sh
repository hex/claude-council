#!/bin/bash
# ABOUTME: Queries a local Ollama server through its OpenAI-compatible endpoint
# ABOUTME: Availability is gated on the ollama binary, not an API key — it is free and local

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"
source "$SCRIPT_DIR/../lib/tokens.sh"
source "$SCRIPT_DIR/../lib/verbosity.sh"

verbosity_prefix VERBOSITY_PREFIX "${COUNCIL_VERBOSITY:-standard}"

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

if ! command -v ollama >/dev/null 2>&1; then
    echo "Error: ollama not found on PATH" >&2
    exit 1
fi

# Local server, no key. OLLAMA_HOST is Ollama's own convention, so an operator
# who already points it at a remote box gets that for free.
HOST="${OLLAMA_HOST:-http://localhost:11434}"
[[ "$HOST" == http* ]] || HOST="http://$HOST"
ENDPOINT="${HOST%/}/v1/chat/completions"

# Model must exist locally (`ollama list`). No sane default id exists across
# machines, so fall back to whichever model is installed first rather than
# hardcoding one that may not be pulled here.
MODEL="${OLLAMA_MODEL:-}"
if [[ -z "$MODEL" ]]; then
    # Guard the call rather than piping it straight into awk. Discovery gates
    # this provider on the binary alone, so "installed but daemon not running"
    # is routine — and there `ollama list` exits non-zero, which under
    # `set -euo pipefail` kills the script on this very assignment, before the
    # empty-MODEL guard below can say anything. The council stores a provider's
    # own output as its error text, so that abort renders a blank error slot.
    # Merging stderr keeps the daemon's diagnostic for the message; on success
    # `ollama list` writes only the table.
    if ! MODEL_LIST=$(ollama list 2>&1); then
        echo "Error: could not reach the Ollama daemon (start it with 'ollama serve'): $(echo "$MODEL_LIST" | head -1)" >&2
        exit 1
    fi
    MODEL=$(echo "$MODEL_LIST" | awk 'NR==2 {print $1}')
    if [[ -z "$MODEL" ]]; then
        echo "Error: no local Ollama model found — run 'ollama pull <model>'" >&2
        exit 1
    fi
fi

# Token limit. Local reasoning models (gpt-oss, deepseek-r1, qwen*, gemma*)
# spend a large share of the budget on thinking that never reaches .content;
# a 2048 default returned an EMPTY answer with finish_reason "length" here, so
# the floor is raised well above the API providers' default.
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-4096}"
bump_for_reasoning TOKENS "$MODEL" "$BASE_TOKENS" '*r1*' '*reason*' '*gpt-oss*' 'qwen*' 'gemma*' 'deepseek*'

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

if [[ -n "$IMAGE_FILE" ]]; then
    jq -n --rawfile prompt "$PROMPT_FILE" --rawfile b64 "$IMAGE_FILE" --arg mime "$IMAGE_MIME" '[
        { type: "text",      text: $prompt },
        { type: "image_url", image_url: { url: ("data:" + $mime + ";base64," + $b64) } }
    ]' > "$CONTENT_FILE"
else
    jq -n --rawfile prompt "$PROMPT_FILE" '$prompt' > "$CONTENT_FILE"
fi

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
        temperature: 0.7,
        max_tokens: $tokens
    }')

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Ollama ===" >&2
    echo "Model: $MODEL" >&2
    echo "Endpoint: $ENDPOINT" >&2
    echo "Max tokens: $TOKENS" >&2
fi

PAYLOAD_FILE=$(mktemp)
trap 'rm -f "$PAYLOAD_FILE" "$OWNED_PROMPT_FILE" "$CONTENT_FILE"' EXIT
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# No Authorization header: a local daemon has no key. A remote OLLAMA_HOST
# behind a proxy would need one, which is out of scope here.
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    --data-binary @"$PAYLOAD_FILE")

if [[ -n "$DEBUG" ]]; then
    echo "=== DEBUG: Response metadata ===" >&2
    echo "$RESPONSE" | jq '{ model: .model, usage: .usage, finish: .choices[0].finish_reason }' >&2 2>/dev/null || true
fi

TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    # A thinking model that hit the cap answers with an empty .content and
    # finish_reason "length" — its whole budget went into .reasoning. Say that
    # plainly instead of reporting an "unknown error" the operator cannot act on.
    FINISH=$(echo "$RESPONSE" | jq -r '.choices[0].finish_reason // empty')
    if [[ "$FINISH" == "length" ]]; then
        echo "Error from Ollama: $MODEL exhausted its ${TOKENS}-token budget on reasoning; raise COUNCIL_MAX_TOKENS" >&2
        exit 1
    fi
    ERROR=$(echo "$RESPONSE" | jq -r '(if (.error | type) == "object" then (.error.message // "") elif (.error | type) == "string" then .error else "" end) | select(. != "") // "Unknown error"')
    echo "Error from Ollama: $ERROR" >&2
    is_model_unavailable_error "$RESPONSE" && exit 3
    exit 1
fi

echo "$TEXT"
