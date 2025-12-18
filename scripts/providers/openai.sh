#!/bin/bash
# ABOUTME: Queries OpenAI API with a prompt
# ABOUTME: Supports both v1/chat/completions and v1/responses endpoints

set -euo pipefail

# Source shared retry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"

# Debug mode: set COUNCIL_DEBUG=1 to see request/response details
DEBUG="${COUNCIL_DEBUG:-}"

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${OPENAI_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: OPENAI_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via OPENAI_MODEL env var)
MODEL="${OPENAI_MODEL:-codex-mini-latest}"

# Token limit (override via COUNCIL_MAX_TOKENS env var)
BASE_TOKENS="${COUNCIL_MAX_TOKENS:-4096}"

# Determine which API to use based on model
# Models requiring v1/responses: codex-*, o3-*, o4-*
if [[ "$MODEL" == codex-* ]] || [[ "$MODEL" == o3-* ]] || [[ "$MODEL" == o4-* ]]; then
    # Use v1/responses API
    ENDPOINT="https://api.openai.com/v1/responses"

    # Reasoning models need higher token limits (reasoning + output combined)
    # Use 8x the base limit, minimum 32768 (OpenAI recommends 25k+)
    TOKENS=$(( BASE_TOKENS * 8 ))
    [[ $TOKENS -lt 32768 ]] && TOKENS=32768

    # Reasoning effort: low/medium/high (override via OPENAI_REASONING_EFFORT)
    EFFORT="${OPENAI_REASONING_EFFORT:-medium}"

    # System instruction
    SYSTEM="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance."

    PAYLOAD=$(jq -n --arg prompt "$PROMPT" --arg model "$MODEL" --argjson tokens "$TOKENS" --arg effort "$EFFORT" --arg system "$SYSTEM" '{
        model: $model,
        instructions: $system,
        input: $prompt,
        max_output_tokens: $tokens,
        reasoning: { effort: $effort }
    }')

    if [[ -n "$DEBUG" ]]; then
        echo "=== DEBUG: OpenAI v1/responses ===" >&2
        echo "Model: $MODEL" >&2
        echo "Max output tokens: $TOKENS" >&2
        echo "Reasoning effort: $EFFORT" >&2
    fi

    RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "$PAYLOAD")

    if [[ -n "$DEBUG" ]]; then
        echo "=== DEBUG: Response metadata ===" >&2
        echo "$RESPONSE" | jq '{
            status: .status,
            usage: .usage,
            output_types: [.output[].type],
            incomplete_details: .incomplete_details
        }' >&2
    fi

    # Extract text from v1/responses format
    # Find the message output (skip reasoning outputs) and get the text
    TEXT=$(echo "$RESPONSE" | jq -r '
        [.output[] | select(.type == "message") | .content[0].text] | first // empty
    ')
else
    # Use v1/chat/completions API
    ENDPOINT="https://api.openai.com/v1/chat/completions"

    # Standard models use base token limit directly
    TOKENS="$BASE_TOKENS"

    # System instruction
    SYSTEM="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance."

    PAYLOAD=$(jq -n --arg prompt "$PROMPT" --arg model "$MODEL" --argjson tokens "$TOKENS" --arg system "$SYSTEM" '{
        model: $model,
        messages: [{
            role: "system",
            content: $system
        }, {
            role: "user",
            content: $prompt
        }],
        temperature: 0.7,
        max_completion_tokens: $tokens
    }')

    RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}" \
        -d "$PAYLOAD")

    # Extract text from chat completions format
    TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
fi

if [[ -z "$TEXT" ]]; then
    # Try multiple error paths
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // .error // empty')
    if [[ -z "$ERROR" ]]; then
        # Show raw response for debugging
        echo "Error from OpenAI: Unable to parse response" >&2
        echo "Raw response: $RESPONSE" >&2
    else
        echo "Error from OpenAI: $ERROR" >&2
    fi
    exit 1
fi

echo "$TEXT"
