# claude-council

A Claude Code plugin that consults multiple AI coding agents to get diverse perspectives on coding problems.

## Features

- Query Gemini, OpenAI (GPT/Codex), and Grok simultaneously
- Side-by-side comparison of responses
- Extensible provider system - add new AI agents easily
- Proactive suggestions for architecture decisions and debugging

## Installation

```bash
# Clone or copy to your plugins directory
claude --plugin-dir /path/to/claude-council
```

## Configuration

### API Keys

Set environment variables (recommended):

```bash
export GEMINI_API_KEY="your-key"
export OPENAI_API_KEY="your-key"
export GROK_API_KEY="your-key"
```

Or create `.claude/claude-council.local.md` in your project:

```yaml
---
providers:
  gemini:
    api_key: "your-key"
  openai:
    api_key: "your-key"
  grok:
    api_key: "your-key"
---
```

### Model Selection

Override default models via environment variables:

```bash
export GEMINI_MODEL="gemini-3-flash-preview"       # default
export OPENAI_MODEL="codex-mini-latest"            # default
export GROK_MODEL="grok-4-1-fast-reasoning"        # default
```

Use more powerful models for complex queries:

```bash
export GEMINI_MODEL="gemini-3-pro-preview"
export OPENAI_MODEL="gpt-5.2"
export GROK_MODEL="grok-4-1-fast-reasoning-latest"
```

### Response Length

Control max tokens per response (default: 4096):

```bash
export COUNCIL_MAX_TOKENS=8192  # longer responses
export COUNCIL_MAX_TOKENS=2048  # shorter, faster responses
```

#### OpenAI Reasoning Models

For OpenAI reasoning models (`codex-*`, `o3-*`, `o4-*`), the token limit is automatically increased to 8x the base value (minimum 32768). This is because these models combine reasoning tokens and output tokens into a single `max_output_tokens` limit.

| Model Type | COUNCIL_MAX_TOKENS | Actual Limit |
|------------|-------------------|--------------|
| Standard (gpt-5.2) | 4096 (default) | 4096 |
| Reasoning (codex-mini-latest) | 4096 (default) | 32768 |
| Reasoning (codex-mini-latest) | 8192 | 65536 |

Control reasoning effort to balance speed vs thoroughness:

```bash
export OPENAI_REASONING_EFFORT="low"     # faster, less reasoning overhead
export OPENAI_REASONING_EFFORT="medium"  # default - balanced
export OPENAI_REASONING_EFFORT="high"    # thorough reasoning, slower
```

Gemini and Grok handle reasoning/thinking tokens separately, so they use the base limit directly.

### Retry Configuration

Automatic retry on transient failures (429 rate limits, 5xx server errors):

```bash
export COUNCIL_MAX_RETRIES=3    # default: 3 retries
export COUNCIL_RETRY_DELAY=1    # default: 1 second initial delay (doubles each retry)
```

## Usage

### Slash Command

```bash
# Query all configured providers
/claude-council:ask "How should I structure authentication in this Express app?"

# Query specific providers
/claude-council:ask --providers=gemini,openai "What's the best approach for caching here?"

# Include a specific file for review
/claude-council:ask --file=src/auth.ts "What's wrong with this implementation?"
```

### Proactive Agent

The `council-advisor` agent will suggest consulting the council when:
- Discussing architecture or design decisions
- Stuck debugging after multiple failed attempts

## Adding New Providers

See the `provider-integration` skill for guidance on adding new AI providers.

## Requirements

- `curl` and `jq` for API calls
- Valid API keys for desired providers
