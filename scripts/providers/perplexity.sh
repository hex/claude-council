#!/bin/bash
# ABOUTME: Queries Perplexity API with a prompt using search-augmented models
# ABOUTME: Returns web-grounded responses with optional citation support

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
API_KEY="${PERPLEXITY_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: PERPLEXITY_API_KEY not set" >&2
    exit 1
fi

# Model selection (override via PERPLEXITY_MODEL env var)
# Available: sonar, sonar-pro, sonar-reasoning, sonar-reasoning-pro
MODEL="${PERPLEXITY_MODEL:-sonar-pro}"

# Perplexity API endpoint (OpenAI-compatible)
ENDPOINT="https://api.perplexity.ai/chat/completions"

# Token limit (override via COUNCIL_MAX_TOKENS env var)
TOKENS="${COUNCIL_MAX_TOKENS:-2048}"

# Search recency filter: day, week, month, year (override via PERPLEXITY_RECENCY)
# Empty means no filter (all time)
RECENCY="${PERPLEXITY_RECENCY:-}"

# System instruction
SYSTEM="You are an expert software engineering consultant. Provide clear, practical responses with code examples where helpful. Be thorough but concise - focus on actionable guidance. When citing sources, include them inline."

# Build request payload
# Perplexity extends OpenAI format with search-specific parameters
if [[ -n "$RECENCY" ]]; then
    PAYLOAD=$(jq -n \
        --arg prompt "$PROMPT" \
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
                content: $prompt
            }],
            temperature: 0.7,
            max_tokens: $tokens,
            return_citations: true,
            search_recency_filter: $recency
        }')
else
    PAYLOAD=$(jq -n \
        --arg prompt "$PROMPT" \
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
                content: $prompt
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

# Make API call
RESPONSE=$(curl_with_retry -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$PAYLOAD")

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

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // .error // "Unknown error"')
    echo "Error from Perplexity: $ERROR" >&2
    exit 1
fi

echo "$TEXT"
