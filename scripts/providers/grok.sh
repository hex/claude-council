#!/bin/bash
# ABOUTME: Queries xAI Grok API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

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

# Build request payload
PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    model: "grok-3-latest",
    messages: [{
        role: "user",
        content: $prompt
    }],
    temperature: 0.7,
    max_tokens: 2048
}')

# Make API call
RESPONSE=$(curl -s -X POST "$ENDPOINT" \
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
