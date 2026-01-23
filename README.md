# claude-council

A Claude Code plugin that consults multiple AI coding agents to get diverse perspectives on coding problems.

## Features

- Query Gemini, OpenAI (GPT/Codex), Grok, and Perplexity simultaneously
- Side-by-side comparison of responses
- Extensible provider system - add new AI agents easily
- Proactive suggestions for architecture decisions and debugging

## Installation

### From Marketplace (Recommended)

```bash
# Add the hex-plugins marketplace
/plugin marketplace add hex/claude-marketplace

# Install claude-council
/plugin install claude-council
```

### Direct from GitHub

```bash
/plugin install hex/claude-council
```

### Manual

```bash
# Clone to your plugins directory
git clone https://github.com/hex/claude-council.git
claude --plugin-dir /path/to/claude-council
```

## Configuration

### API Keys

Set environment variables (recommended):

```bash
export GEMINI_API_KEY="your-key"
export OPENAI_API_KEY="your-key"
export GROK_API_KEY="your-key"
export PERPLEXITY_API_KEY="your-key"
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
  perplexity:
    api_key: "your-key"
---
```

### Model Selection

Override default models via environment variables:

```bash
export GEMINI_MODEL="gemini-3-flash-preview"       # default
export OPENAI_MODEL="codex-mini-latest"            # default
export GROK_MODEL="grok-4-1-fast-reasoning"        # default
export PERPLEXITY_MODEL="sonar-pro"                # default (search-augmented)
```

Use more powerful models for complex queries:

```bash
export GEMINI_MODEL="gemini-3-pro-preview"
export OPENAI_MODEL="gpt-5.2"
export GROK_MODEL="grok-4-1-fast-reasoning-latest"
export PERPLEXITY_MODEL="sonar-reasoning-pro"      # with chain-of-thought
```

### Response Length

Control max tokens per response (default: 2048):

```bash
export COUNCIL_MAX_TOKENS=4096  # longer responses
export COUNCIL_MAX_TOKENS=1024  # shorter, faster responses
```

#### OpenAI Reasoning Models

For OpenAI reasoning models (`codex-*`, `o3-*`, `o4-*`), the token limit is automatically increased to 8x the base value (minimum 32768). This is because these models combine reasoning tokens and output tokens into a single `max_output_tokens` limit.

| Model Type | COUNCIL_MAX_TOKENS | Actual Limit |
|------------|-------------------|--------------|
| Standard (gpt-5.2) | 2048 (default) | 2048 |
| Reasoning (codex-mini-latest) | 2048 (default) | 32768 |
| Reasoning (codex-mini-latest) | 4096 | 32768 |

Control reasoning effort to balance speed vs thoroughness:

```bash
export OPENAI_REASONING_EFFORT="low"     # faster, less reasoning overhead
export OPENAI_REASONING_EFFORT="medium"  # default - balanced
export OPENAI_REASONING_EFFORT="high"    # thorough reasoning, slower
```

Gemini and Grok handle reasoning/thinking tokens separately, so they use the base limit directly.

#### Perplexity Search Features

Perplexity's sonar models are search-augmented, providing web-grounded responses with citations:

```bash
# Filter search results by recency: day, week, month, year
export PERPLEXITY_RECENCY="week"
```

Available models:
- `sonar` - Fast, search-enabled
- `sonar-pro` - More capable, search-enabled (default)
- `sonar-reasoning` - Chain-of-thought reasoning + search
- `sonar-reasoning-pro` - Best reasoning + search

Perplexity is useful when you need current information (latest framework versions, recent best practices) rather than just training-data knowledge.

### Retry & Timeout Configuration

Automatic retry on transient failures (429 rate limits, 5xx server errors):

```bash
export COUNCIL_MAX_RETRIES=3    # default: 3 retries
export COUNCIL_RETRY_DELAY=1    # default: 1 second initial delay (doubles each retry)
export COUNCIL_TIMEOUT=60       # default: 60 seconds per request
```

Timeouts fail fast (no retry) to prevent blocking on hung providers.

## Usage

### Quick Reference

| Flag | Description |
|------|-------------|
| `--providers=list` | Query specific providers (e.g., `gemini,openai`) |
| `--roles=list` | Assign roles to providers (e.g., `security,performance` or `balanced`) |
| `--debate` | Enable two-round debate mode |
| `--file=path` | Include specific file in context |
| `--output=path` | Export response to markdown file |
| `--quiet` | Show only synthesis, hide individual responses |
| `--no-cache` | Force fresh queries, skip cache |
| `--no-auto-context` | Disable automatic file detection |

### Slash Command

```bash
# Query all configured providers
/claude-council:ask "How should I structure authentication in this Express app?"

# Query specific providers
/claude-council:ask --providers=gemini,openai "What's the best approach for caching here?"

# Include a specific file for review
/claude-council:ask --file=src/auth.ts "What's wrong with this implementation?"

# Export response to markdown file
/claude-council:ask --output=docs/auth-decision.md "How should we implement authentication?"

# Quiet mode - show only synthesis
/claude-council:ask --quiet "What's the best caching strategy?"
```

### Export to File

Save council responses as clean markdown files for documentation or sharing:

```bash
/claude-council:ask --output=docs/decision.md "Should we use REST or GraphQL?"
```

The exported file includes:
- Metadata header (query, date, providers)
- Each provider's full response
- Synthesis with consensus/divergence analysis

Great for:
- Documenting architectural decisions
- Sharing with team members who aren't using Claude
- Creating an audit trail of AI-assisted decisions

### Quiet Mode

Get just the bottom line without individual provider responses:

```bash
/claude-council:ask --quiet "Should I use Redis or Memcached?"
```

Quiet mode still queries all providers and analyzes their responses, but only shows the synthesis with consensus/divergence analysis. Use when you want a quick answer without scrolling through multiple perspectives.

### Response Caching

Responses are automatically cached to speed up repeated queries and save API costs:

```bash
# Uses cache if available (default)
/claude-council:ask "What's the best testing framework?"

# Force fresh queries, skip cache
/claude-council:ask --no-cache "What's the best testing framework?"
```

Cache configuration:
```bash
export COUNCIL_CACHE_DIR=".claude/council-cache"  # Cache location (default)
export COUNCIL_CACHE_TTL=3600                      # Cache lifetime in seconds (default: 1 hour)
```

Cached responses show `cached` instead of `success` in the status output. Cache is keyed by prompt + provider + model + role, so:
- Changing models invalidates the cache
- Using `--roles` creates separate cache entries (same prompt with different role = cache miss)
- Debate mode round 2 rebuttals are never cached (they depend on round 1 content)

### Auto-Context Injection

The council automatically detects and includes relevant files based on your question:

```bash
/claude-council:ask "How should I refactor the authentication flow?"
# Auto-detects and includes: src/auth/*.ts, middleware/auth.ts, etc.
```

Before querying, you'll see which files were auto-included:
```
Auto-included context (3 files):
  - src/auth/handler.ts (keyword: "auth")
  - middleware/session.ts (keyword: "session")
  - types/user.ts (keyword: "user")
```

To disable auto-context (for general questions not about your code):
```bash
/claude-council:ask --no-auto-context "What are best practices for API design?"
```

Auto-context limits:
- Maximum 5 files included
- Maximum ~10,000 tokens of context
- Skipped if you provide `--file=` explicitly

### Specialized Roles

Assign different perspectives to each provider for more comprehensive reviews:

```bash
# Use specific roles
/claude-council:ask --roles=security,performance,maintainability "Review this auth code"

# Use a preset
/claude-council:ask --roles=balanced "Review this implementation"
```

**Available roles:**
- `security` - Security Auditor (vulnerabilities, OWASP Top 10)
- `performance` - Performance Optimizer (efficiency, bottlenecks)
- `maintainability` - Maintainability Advocate (clarity, future changes)
- `devil` - Devil's Advocate (challenges assumptions)
- `simplicity` - Simplicity Champion (identifies over-engineering)
- `scalability` - Scalability Architect (growth, scaling)
- `dx` - Developer Experience (API ergonomics)
- `compliance` - Compliance Officer (GDPR, regulations)

**Presets:**
- `balanced` - security, performance, maintainability
- `security-focused` - security, devil, compliance
- `architecture` - scalability, maintainability, simplicity
- `review` - security, maintainability, dx

Roles are assigned to providers in order, ensuring each provider approaches the question from a different angle.

### Debate Mode

Enable multi-round discussions where providers critique each other:

```bash
/claude-council:ask --debate "How should I structure the database schema?"
```

**How it works:**
1. **Round 1**: All providers answer the question normally
2. **Round 2**: Each provider sees the others' responses and provides rebuttals
3. **Synthesis**: Incorporates debate insights, consensus shifts, and unresolved tensions

Debate mode surfaces blind spots and stress-tests recommendations. The synthesis includes:
- Strongest criticisms raised
- Where providers changed positions after seeing alternatives
- Genuine disagreements that remain

Combine with roles for focused debates:
```bash
/claude-council:ask --debate --roles=security,performance,simplicity "Review this architecture"
```

### Proactive Agent

The `council-advisor` agent will suggest consulting the council when:
- Discussing architecture or design decisions
- Stuck debugging after multiple failed attempts

## Adding New Providers

See the `provider-integration` skill for guidance on adding new AI providers.

## Direct Script Usage

Use the scripts directly without Claude Code (for automation, CI, or debugging):

```bash
# Basic query - returns JSON
bash scripts/query-council.sh "What is dependency injection?"

# With flags
bash scripts/query-council.sh --providers=gemini,openai --roles=balanced "Review this pattern"

# Pipe to formatter for terminal display
bash scripts/query-council.sh --providers=gemini "Question" 2>/dev/null | bash scripts/format-output.sh

# Check provider status
bash scripts/check-status.sh
```

**JSON output structure:**
```json
{
  "metadata": {
    "prompt": "...",
    "roles_used": ["security", "performance"],
    "debate_mode": false,
    "quiet_mode": false,
    "timestamp": "2025-12-18T12:00:00Z"
  },
  "round1": {
    "gemini": { "status": "success", "response": "...", "model": "...", "role": "security" },
    "openai": { "status": "success", "response": "...", "model": "...", "role": "performance" }
  },
  "round2": { ... }  // Only present if --debate
}
```

## Requirements

- `curl` and `jq` for API calls
- Valid API keys for desired providers

## Development

### Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for system design, data flow diagrams, and component details.

### Versioning

Bump version in `.claude-plugin/plugin.json` on every release:

```json
{
  "version": "YYYY.M.PATCH"
}
```

Format: `YYYY.M.PATCH` where PATCH increments with each release. Examples: `2026.1.1`, `2026.1.2`, `2026.2.1`.

**Always bump version when:**
- Changing command behavior
- Fixing bugs
- Updating formatting/output
- Any change users should pull

### Testing

```bash
# Run automated tests (requires bats-core)
./tests/run_tests.sh

# Run specific test suite
bats tests/cache.bats
bats tests/roles.bats
```

See `TESTING.md` for complete test documentation including manual test procedures.

### Release Checklist

1. Make changes
2. Test locally
3. Bump version in `.claude-plugin/plugin.json`
4. Commit and push
5. Users update via `/plugin update claude-council`
