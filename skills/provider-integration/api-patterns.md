# Provider API Patterns Reference

## OpenAI-Compatible APIs

Many providers use OpenAI-compatible endpoints (Grok, Together, etc.):

```bash
ENDPOINT="https://api.{provider}.com/v1/chat/completions"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    model: "model-name",
    messages: [{role: "user", content: $prompt}],
    temperature: 0.7,
    max_tokens: 1024
}')

RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
```

## Google Gemini Pattern

```bash
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/gemini-3-flash-preview:generateContent"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    contents: [{parts: [{text: $prompt}]}],
    generationConfig: {temperature: 0.7, maxOutputTokens: 1024}
}')

RESPONSE=$(curl -s -X POST "${ENDPOINT}?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty')
```

## Anthropic Claude Pattern

```bash
ENDPOINT="https://api.anthropic.com/v1/messages"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    model: "claude-sonnet-4-20250514",
    max_tokens: 1024,
    messages: [{role: "user", content: $prompt}]
}')

RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty')
```

## Provider Script Template

```bash
#!/bin/bash
# ABOUTME: Queries {Provider} API with a prompt
# ABOUTME: Returns the model's response to stdout

set -euo pipefail

PROMPT="${1:-}"

if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided" >&2
    exit 1
fi

API_KEY="${PROVIDER_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
    echo "Error: PROVIDER_API_KEY not set" >&2
    exit 1
fi

# Make API call (adjust for provider's API format)
RESPONSE=$(curl -s -X POST "https://api.provider.com/v1/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$(jq -n --arg prompt "$PROMPT" '{
        model: "model-name",
        messages: [{role: "user", content: $prompt}]
    }')")

TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
    echo "Error: $ERROR" >&2
    exit 1
fi

echo "$TEXT"
```

## Adding Popular Providers

### Mistral AI
- Endpoint: `https://api.mistral.ai/v1/chat/completions`
- Key: `MISTRAL_API_KEY`
- Model: `mistral-large-latest`
- Format: OpenAI-compatible

### Cohere
- Endpoint: `https://api.cohere.ai/v1/chat`
- Key: `COHERE_API_KEY`
- Model: `command-r-plus`
- Format: Custom (see Cohere docs)
