#!/bin/bash
# ABOUTME: Queries xAI Grok API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

# Source shared retry library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/retry.sh"

# Debug mode
DEBUG="${COUNCIL_DEBUG:-}"

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${GROK_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: GROK_API_KEY not set" >&2
    exit 1
fi

# xAI API endpoint (OpenAI-compatible)
ENDPOINT="https://api.x.ai/v1/chat/completions"

# Model selection (override via GROK_MODEL env var)
MODEL="${GROK_MODEL:-grok-4-1-fast-reasoning}"

# Token limit (override via COUNCIL_MAX_TOKENS env var)
TOKENS="${COUNCIL_MAX_TOKENS:-1024}"

# System instruction
SYSTEM="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance."

# Build request payload
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
    max_tokens: $tokens
}')

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$PAYLOAD")

# Extract text from response
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
    echo "Error from Grok: $ERROR" >&2
    exit 1
fi

echo "$TEXT"
