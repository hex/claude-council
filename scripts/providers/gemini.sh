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

# Model selection (override via GEMINI_MODEL env var)
MODEL="${GEMINI_MODEL:-gemini-3-flash-preview}"

# Gemini API endpoint
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

# Token limit (override via COUNCIL_MAX_TOKENS env var)
TOKENS="${COUNCIL_MAX_TOKENS:-4096}"

# System instruction
SYSTEM="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance."

# Build request payload
PAYLOAD=$(jq -n --arg prompt "$PROMPT" --argjson tokens "$TOKENS" --arg system "$SYSTEM" '{
    system_instruction: {
        parts: [{
            text: $system
        }]
    },
    contents: [{
        parts: [{
            text: $prompt
        }]
    }],
    generationConfig: {
        temperature: 0.7,
        maxOutputTokens: $tokens
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
