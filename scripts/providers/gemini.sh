#!/bin/bash
# ABOUTME: Queries Google Gemini API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

# Check for API key
API_KEY="${GEMINI_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: GEMINI_API_KEY not set" >&2
    exit 1
fi

# Gemini API endpoint
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"

# Build request payload
PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    contents: [{
        parts: [{
            text: $prompt
        }]
    }],
    generationConfig: {
        temperature: 0.7,
        maxOutputTokens: 2048
    }
}')

# Make API call
RESPONSE=$(curl -s -X POST \
    "${ENDPOINT}?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

# Extract text from response
TEXT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
    echo "Error from Gemini: $ERROR" >&2
    exit 1
fi

echo "$TEXT"
