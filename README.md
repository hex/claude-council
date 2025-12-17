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

## Usage

### Slash Command

```bash
# Query all configured providers
/council "How should I structure authentication in this Express app?"

# Query specific providers
/council --providers=gemini,openai "What's the best approach for caching here?"

# Include a specific file for review
/council --file=src/auth.ts "What's wrong with this implementation?"

# Combine flags
/council --file=src/api.ts --providers=gemini "Review this code"
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
