# Provider API Patterns Reference

## OpenAI-Compatible APIs

Many providers use OpenAI-compatible endpoints (Grok, Together, etc.):

```bash
ENDPOINT="https://api.{provider}.com/v1/chat/completions"

# --rawfile, not --arg: the prompt is read from the file the orchestrator wrote
# so it never rides jq's argv, which MSYS caps near 32KB just like execve's.
PAYLOAD=$(jq -n --rawfile prompt "$PROMPT_FILE" '{
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
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/gemini-pro-latest:generateContent"

PAYLOAD=$(jq -n --rawfile prompt "$PROMPT_FILE" '{
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

PAYLOAD=$(jq -n --rawfile prompt "$PROMPT_FILE" '{
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
# The orchestrator passes --prompt-file so a large prompt stays off argv; keep
# the path, because jq reads it with --rawfile for the same reason.
PROMPT_FILE=""
if [[ "$PROMPT" == "--prompt-file" ]]; then
    PROMPT_FILE="${2:?--prompt-file requires a path}"
    PROMPT=$(cat "$PROMPT_FILE")
    shift 2
fi

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
    -d "$(jq -n --rawfile prompt "$PROMPT_FILE" '{
        model: "model-name",
        messages: [{role: "user", content: $prompt}]
    }')")

TEXT=$(echo "$RESPONSE" | jq -r '(.choices[0].message.content)? // empty')

# Whitespace-stripped, not a bare -z: a model that answers with a single space
# would otherwise be cached and weighed in the synthesis as a real vote.
if [[ -z "${TEXT//[[:space:]]/}" ]]; then
    # Branch on the type before indexing. .error is an object for most vendors
    # and a bare string for some; indexing a string raises in jq rather than
    # yielding null, `//` does not catch a raise, and under set -eo pipefail
    # that raise kills the seat before it prints any error line at all.
    ERROR=$(echo "$RESPONSE" | jq -r '
        (if (.error | type) == "object" then (.error.message // "")
         elif (.error | type) == "string" then .error
         else "" end | tostring) as $top
        | if $top != "" then $top else "Unknown error" end')
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
