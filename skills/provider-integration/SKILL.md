---
name: Provider Integration
description: Use this skill when adding a new AI provider to claude-council, configuring provider API settings, troubleshooting provider connections, or understanding the provider script interface. Triggers on "add provider", "new AI agent", "provider not working", "API configuration", or "extend council".
version: 0.1.0
---

# Adding AI Providers to Claude Council

## Provider Script Interface

Each provider is a shell script in `scripts/providers/` that:
1. Accepts a prompt as the first argument
2. Outputs the AI response to stdout
3. Exits 0 on success, non-zero on failure
4. Reports errors to stderr

## Creating a New Provider

### Step 1: Create Provider Script

Create `scripts/providers/{provider-name}.sh`:

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

# Check for API key
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

# Extract response (adjust for provider's response format)
TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')

if [[ -z "$TEXT" ]]; then
    ERROR=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
    echo "Error: $ERROR" >&2
    exit 1
fi

echo "$TEXT"
```

### Step 2: Make Script Executable

```bash
chmod +x scripts/providers/{provider-name}.sh
```

### Step 3: Set API Key

The script expects `{PROVIDER}_API_KEY` environment variable:

```bash
export PROVIDER_API_KEY="your-api-key"
```

Or add to `.claude/claude-council.local.md`:

```yaml
---
providers:
  provider-name:
    api_key: "your-api-key"
---
```

### Step 4: Test Provider

```bash
# Test directly
./scripts/providers/{provider-name}.sh "Hello, can you respond?"

# Test via council
./scripts/query-council.sh --providers={provider-name} "Test query"
```

## Provider API Patterns

### OpenAI-Compatible APIs

Many providers use OpenAI-compatible endpoints (Grok, Together, etc.):

```bash
ENDPOINT="https://api.{provider}.com/v1/chat/completions"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    model: "model-name",
    messages: [{role: "user", content: $prompt}],
    temperature: 0.7,
    max_tokens: 2048
}')

RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${API_KEY}" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty')
```

### Google Gemini Pattern

```bash
ENDPOINT="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    contents: [{parts: [{text: $prompt}]}],
    generationConfig: {temperature: 0.7, maxOutputTokens: 2048}
}')

RESPONSE=$(curl -s -X POST "${ENDPOINT}?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.candidates[0].content.parts[0].text // empty')
```

### Anthropic Claude Pattern

```bash
ENDPOINT="https://api.anthropic.com/v1/messages"

PAYLOAD=$(jq -n --arg prompt "$PROMPT" '{
    model: "claude-sonnet-4-20250514",
    max_tokens: 2048,
    messages: [{role: "user", content: $prompt}]
}')

RESPONSE=$(curl -s -X POST "$ENDPOINT" \
    -H "Content-Type: application/json" \
    -H "x-api-key: ${API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -d "$PAYLOAD")

TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty')
```

## Troubleshooting

### Provider Not Discovered

The `query-council.sh` script only discovers providers with configured API keys:

```bash
# Check if key is set
echo $PROVIDER_API_KEY

# Verify script is executable
ls -la scripts/providers/*.sh
```

### API Errors

Common issues:
- **Invalid API key**: Check key is correct and not expired
- **Rate limiting**: Add retry logic or slow down requests
- **Model not available**: Check model name in provider docs
- **Quota exceeded**: Check account billing/limits

### Response Parsing Fails

If `jq` fails to extract response:
1. Add `echo "$RESPONSE"` before parsing to see raw response
2. Check provider's actual response format in their docs
3. Adjust `jq` path to match response structure

## Available Providers

Current providers in `scripts/providers/`:

| Provider | Script | API Key Variable | Model |
|----------|--------|------------------|-------|
| Gemini | gemini.sh | GEMINI_API_KEY | gemini-2.0-flash |
| OpenAI | openai.sh | OPENAI_API_KEY | gpt-4o |
| Grok | grok.sh | GROK_API_KEY | grok-3-latest |

## Adding Popular Providers

### Anthropic Claude

Would create recursion (asking Claude about Claude), but if needed:

```bash
# scripts/providers/anthropic.sh
# Uses ANTHROPIC_API_KEY
# Model: claude-sonnet-4-20250514
```

### Mistral AI

```bash
# Endpoint: https://api.mistral.ai/v1/chat/completions
# Key: MISTRAL_API_KEY
# Model: mistral-large-latest
# Format: OpenAI-compatible
```

### Cohere

```bash
# Endpoint: https://api.cohere.ai/v1/chat
# Key: COHERE_API_KEY
# Model: command-r-plus
# Format: Custom (see Cohere docs)
```
