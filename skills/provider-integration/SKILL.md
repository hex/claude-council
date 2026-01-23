---
description: Use this skill when adding a new AI provider to claude-council, configuring provider API settings, troubleshooting provider connections, or understanding the provider script interface. Triggers on "add provider", "new AI agent", "provider not working", "API configuration", or "extend council".
---

# Adding AI Providers to Claude Council

## Provider Script Interface

Each provider is a shell script in `scripts/providers/` that:
1. Accepts a prompt as the first argument
2. Outputs the AI response to stdout
3. Exits 0 on success, non-zero on failure

## Quick Start

1. Create `scripts/providers/{name}.sh` (see `api-patterns.md` for templates)
2. `chmod +x scripts/providers/{name}.sh`
3. Set `{NAME}_API_KEY` environment variable
4. Test: `./scripts/providers/{name}.sh "Hello"`

## Current Providers

| Provider | API Key Variable | Default Model |
|----------|------------------|---------------|
| Gemini | `GEMINI_API_KEY` | gemini-3-flash-preview |
| OpenAI | `OPENAI_API_KEY` | codex-mini-latest |
| Grok | `GROK_API_KEY` | grok-4-1-fast-reasoning |
| Perplexity | `PERPLEXITY_API_KEY` | sonar-pro |

## Troubleshooting

- **Not discovered**: Check API key is set and script is executable
- **API errors**: Verify key, check rate limits, confirm model name
- **Parse fails**: Add `echo "$RESPONSE"` to debug, check response format

## Reference

For API patterns and code templates, see `api-patterns.md` in this directory.
