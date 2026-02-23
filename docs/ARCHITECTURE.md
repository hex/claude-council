# Architecture

## System Overview

```
                           USER REQUEST
                                |
                                v
                    +------------------------+
                    |   /claude-council:ask  |
                    |     (commands/ask.md)  |
                    +------------------------+
                                |
                                v
+------------------------------------------------------------------------+
|                        query-council.sh                                 |
|------------------------------------------------------------------------|
|  1. Parse Arguments (--providers, --roles, --debate, --file, etc.)     |
|  2. Discover Available Providers (check API keys)                      |
|  3. Resolve Roles (expand presets, assign to providers)                |
|  4. Build Context (--file content, auto-context detection)             |
+------------------------------------------------------------------------+
                                |
                                v
                    +------------------------+
                    |     ROUND 1: Query     |
                    +------------------------+
                                |
        +---------------+-------+-------+---------------+
        |               |               |               |
        v               v               v               v
  +-----------+   +-----------+   +-----------+   +-----------+
  |  gemini   |   |  openai   |   |   grok    |   | perplexity|
  |   .sh     |   |   .sh     |   |   .sh     |   |    .sh    |
  +-----------+   +-----------+   +-----------+   +-----------+
        |               |               |               |
        |    +----------+----------+----------+        |
        +--->|      lib/cache.sh   |<---------+--------+
             | (check/store cache) |
             +---------------------+
                      |
        +-------------+-------------+
        |             |             |
        v             v             v
   [CACHE HIT]   [CACHE MISS]   [ERROR]
        |             |             |
        |             v             |
        |      +-------------+      |
        |      | lib/retry.sh|      |
        |      | (exp backoff|      |
        |      |  429/5xx)   |      |
        |      +-------------+      |
        |             |             |
        +------+------+------+------+
               |
               v
    +---------------------+
    | Collect R1 Results  |
    | {provider: {status, |
    |   response, cached, |
    |   role, model}}     |
    +---------------------+
               |
               +------ [if --debate] ------+
               |                           |
               v                           v
    +-------------------+       +------------------------+
    | Output R1 Results |       |   ROUND 2: Rebuttals   |
    +-------------------+       +------------------------+
                                           |
                        +------------------+------------------+
                        |                  |                  |
                        v                  v                  v
                  +-----------+      +-----------+      +-----------+
                  | Provider A|      | Provider B|      | Provider C|
                  | sees B,C  |      | sees A,C  |      | sees A,B  |
                  | responses |      | responses |      | responses |
                  +-----------+      +-----------+      +-----------+
                        |                  |                  |
                        +--------+---------+--------+---------+
                                 |
                                 v
                      +---------------------+
                      | Collect R2 Results  |
                      +---------------------+
                                 |
               +-----------------+
               |
               v
    +---------------------+
    |   Build JSON Output |
    |---------------------|
    | {                   |
    |   metadata: {...},  |
    |   round1: {...},    |
    |   round2: {...}     |  <-- only if debate
    | }                   |
    +---------------------+
               |
               v
    +---------------------+
    | format-output.sh    |
    | (terminal display)  |
    +---------------------+
               |
               v
    +---------------------+
    | lib/export.sh       |  <-- if --output
    | (markdown file)     |
    +---------------------+
```

## Component Details

### Provider Scripts (`scripts/providers/*.sh`)

Each provider follows a consistent interface:

```
INPUT:  $1 = prompt (with role prefix if assigned)
OUTPUT: stdout = AI response text
EXIT:   0 = success, non-zero = failure (error to stderr)
```

Environment-based configuration:
- `{PROVIDER}_API_KEY` - Required authentication
- `{PROVIDER}_MODEL` - Model override
- `COUNCIL_MAX_TOKENS` - Response length limit
- `COUNCIL_DEBUG` - Enable verbose logging

### Cache Layer (`scripts/lib/cache.sh`)

```
Cache Key = SHA256(provider + model + prompt)

cache_get(key) -> response | empty
cache_set(key, provider, model, prompt, response)
cache_clear()

Storage: $COUNCIL_CACHE_DIR/{key}.json
TTL: $COUNCIL_CACHE_TTL seconds (default 3600)
```

### Retry Logic (`scripts/lib/retry.sh`)

```
curl_with_retry():
  - Retries on: 429 (rate limit), 5xx (server error)
  - Fails fast on: timeout, 4xx (client error)
  - Backoff: exponential (1s, 2s, 4s...)
  - Max retries: $COUNCIL_MAX_RETRIES (default 3)
```

### Role System (`scripts/lib/roles.sh`)

```
config/roles.json defines:
  - Individual roles (security, performance, etc.)
  - Role presets (balanced, security-focused, etc.)

Role injection prepends instructions to prompt:
  "As a [ROLE], focus on [CONCERNS]..."
```

## Data Flow

### Standard Query

```
User -> parse args -> discover providers -> check cache
                                               |
                    +-----------+--------------+
                    |           |
               [HIT]         [MISS]
                 |              |
                 |         query API -> store cache
                 |              |
                 +------+-------+
                        |
                    format output -> display
```

### Debate Mode

```
User -> Round 1 (parallel queries)
             |
        collect responses
             |
        Round 2 (each sees others' R1)
             |
        collect rebuttals
             |
        combined output with debate insights
```

## File Structure

```
claude-council/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── agents/
│   └── council-advisor.md       # Proactive suggestions
├── commands/
│   ├── ask.md                   # Main /ask command
│   └── status.md                # /status command
├── config/
│   └── roles.json               # Role definitions
├── docs/
│   └── ARCHITECTURE.md          # This file
├── scripts/
│   ├── query-council.sh         # Main orchestrator
│   ├── run-council.sh           # Query + format pipeline
│   ├── format-output.sh         # Terminal formatter
│   ├── check-status.sh          # Provider health check
│   ├── release.sh               # Version bump and tagging
│   ├── providers/
│   │   ├── gemini.sh
│   │   ├── openai.sh
│   │   ├── grok.sh
│   │   └── perplexity.sh
│   └── lib/
│       ├── cache.sh             # Caching utilities
│       ├── retry.sh             # Retry with backoff
│       ├── roles.sh             # Role management
│       └── export.sh            # Markdown export
├── skills/
│   ├── council-execution/
│   │   └── SKILL.md             # Query execution guidance
│   └── provider-integration/
│       ├── SKILL.md             # Adding providers guide
│       └── api-patterns.md      # API integration patterns
├── tests/
│   ├── run_tests.sh             # Test runner
│   ├── test_helper.bash         # Shared test utilities
│   ├── cache.bats
│   ├── roles.bats
│   └── query-council.bats
├── AGENTS.md
├── LICENSE
├── README.md
└── TESTING.md
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_API_KEY` | - | Google AI Studio key |
| `OPENAI_API_KEY` | - | OpenAI API key |
| `GROK_API_KEY` | - | xAI API key |
| `PERPLEXITY_API_KEY` | - | Perplexity API key |
| `{PROVIDER}_MODEL` | varies | Model override |
| `COUNCIL_MAX_TOKENS` | 2048 | Max response tokens |
| `COUNCIL_MAX_RETRIES` | 3 | Retry attempts |
| `COUNCIL_RETRY_DELAY` | 1 | Initial retry delay (s) |
| `COUNCIL_TIMEOUT` | 60 | Request timeout (s) |
| `COUNCIL_CACHE_DIR` | .claude/council-cache | Cache location |
| `COUNCIL_CACHE_TTL` | 3600 | Cache lifetime (s) |
| `COUNCIL_DEBUG` | - | Enable debug output |
| `OPENAI_REASONING_EFFORT` | medium | Reasoning model effort |
| `PERPLEXITY_RECENCY` | - | Search recency filter |
