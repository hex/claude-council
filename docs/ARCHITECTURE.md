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
|  2. Discover Available Providers (API key OR CLI binary on PATH)       |
|  3. Apply CLI-prefers-API policy (codex shadows openai, etc.)          |
|  4. Resolve Roles (expand presets, assign to providers)                |
|  5. Build Context (--file content, auto-context detection)             |
+------------------------------------------------------------------------+
                                |
                                v
                    +------------------------+
                    |     ROUND 1: Query     |
                    +------------------------+
                                |
        +-------+-------+-------+-------+-------+-------+
        |       |       |       |       |       |       |
        v       v       v       v       v       v       v
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+
   | gemini | |open | | grok | |perp | |codex | | gemini-cli|
   |  .sh   | | .sh | |  .sh | |.sh  | |  .sh | |    .sh    |
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+
   (API)      (API)   (API)    (API)   (CLI)    (CLI)
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

Two flavors share the interface:

- **API providers** (`gemini`, `openai`, `grok`, `perplexity`) — gated on
  `{PROVIDER}_API_KEY`, talk to vendor APIs over HTTPS, charge per call.
- **CLI providers** (`codex`, `gemini-cli`) — gated on the binary being on
  `PATH`, use the user's existing CLI subscription auth, no per-call cost.
  When both an API and CLI sibling exist (codex+openai, gemini-cli+gemini),
  the orchestrator prefers the CLI by default; explicit `--providers` wins
  over the policy.

Environment-based configuration:
- `{PROVIDER}_API_KEY` - Required authentication for API providers
- `{PROVIDER}_MODEL` - Model override (also applies to CLI providers via
  `CODEX_MODEL` / `GEMINI_CLI_MODEL`)
- `COUNCIL_MAX_TOKENS` - Response length limit (API providers only)
- `COUNCIL_DEBUG` - Enable verbose logging

### Cache Layer (`scripts/lib/cache.sh`)

```
Cache Key = SHA256("provider:model:prompt")

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
  - Fails fast on: timeout, other 4xx (client error)
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

### Prompt Templates (`scripts/lib/prompts.sh`, `prompts/*.md`)

```
load_prompt_template(name):  reads prompts/<name>.md
interpolate_template(t, KEY=VALUE...): fills {{KEY}} slots
  - unfilled slots collapse to empty
Templates: role-injection, synthesis (calibration rules),
           stop-review-gate (ALLOW:/BLOCK: first-line contract)
```

### Job Store (`scripts/lib/jobs.sh`)

```
State dir: $COUNCIL_JOBS_DIR, else
           $CLAUDE_PLUGIN_DATA/jobs/<cwd-hash>, else tmp
Per job:   <id>.json (status, pid, outfile, timestamps) + <id>.log
Lifecycle: queued -> running -> completed | failed | cancelled
  - run-council.sh --async re-execs itself detached as --job-worker=<id>
  - worker exit trap converts crashes to failed
  - --result echoes the outfile path (exit 2 while in flight)
  - --cancel marks cancelled first, then kills the process tree
  - jobs_prune drops oldest terminal jobs beyond COUNCIL_MAX_JOBS
```

### Output Contract (`schemas/`, `scripts/validate-analysis.sh`)

```
schemas/agent-analysis.schema.json documents the deep-execution
agent reply shape; validate-analysis.sh enforces it with jq,
listing every violation. Invalid replies render raw under a
visible marker - model output is never silently dropped
(same rule as format-output.sh's render_response).
```

### Stop Gate (`hooks/hooks.json`, `scripts/stop-review-gate.sh`)

```
Stop hook, opt-in via .claude/council-stop-gate.json.
Reviews `git diff HEAD` through one provider using the
stop-review-gate prompt; blocks only on first-line BLOCK:.
Loop guards: stop_hook_active check + per-session block
counter capped at max_iterations. Reviewer failure => allow.
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

### Agent-Enhanced Mode (--agents)

```
User -> ask.md detects --agents flag (or NL trigger)
             |
        spawn N parallel Claude subagents (background)
             |
    +--------+--------+--------+--------+
    |        |        |        |        |
    v        v        v        v        v
 Agent:   Agent:   Agent:   Agent:   ...
 Gemini   OpenAI   Grok     Perplexity
    |        |        |        |
    | Each agent independently:
    | 1. Runs provider curl script
    | 2. Evaluates response quality
    | 3. Retries with reformulated prompt if poor
    | 4. Asks follow-up questions for depth
    | 5. Returns structured analysis:
    |    - Key recommendations
    |    - Confidence level
    |    - Unique perspective
    |    - Blind spots
    |        |        |        |
    +--------+--------+--------+
             |
        orchestrator collects all analyses
             |
        enhanced synthesis:
        - confidence-weighted consensus
        - cross-provider blind spot analysis
        - divergence with context
             |
        save to council-cache
```

Key difference from standard mode: subagents do meaningful analytical
work beyond the API call, pre-digesting each response before synthesis.

## File Structure

```
claude-council/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── agents/
│   └── council-advisor.md       # Proactive suggestions
├── commands/
│   ├── ask.md                   # Main /ask command
│   ├── result.md                # /result — fetch/list/cancel background jobs
│   └── status.md                # /status command
├── config/
│   └── roles.json               # Role definitions
├── docs/
│   └── ARCHITECTURE.md          # This file
├── hooks/
│   └── hooks.json               # Stop hook registration (stop gate)
├── prompts/
│   ├── role-injection.md        # {{VAR}} template for role-wrapped prompts
│   ├── synthesis.md             # Synthesis structure + calibration rules
│   └── stop-review-gate.md      # Stop-gate reviewer contract
├── schemas/
│   └── agent-analysis.schema.json  # Deep-execution agent reply contract
├── scripts/
│   ├── query-council.sh         # Main orchestrator
│   ├── run-council.sh           # Query + format pipeline, sync and --async
│   ├── format-output.sh         # Terminal formatter
│   ├── check-status.sh          # Provider health check
│   ├── stop-review-gate.sh      # Opt-in Stop hook reviewer
│   ├── validate-analysis.sh     # Enforces the agent-analysis schema
│   ├── release.sh               # Version bump and tagging
│   ├── dev/
│   │   └── demo-pane.sh         # Visual test harness for the streaming pane
│   ├── providers/
│   │   ├── gemini.sh            # API
│   │   ├── openai.sh            # API
│   │   ├── grok.sh              # API
│   │   ├── perplexity.sh        # API
│   │   ├── codex.sh             # CLI (subscription auth, shadows openai)
│   │   └── gemini-cli.sh        # CLI (subscription auth, shadows gemini)
│   └── lib/
│       ├── cache.sh             # Caching utilities
│       ├── display.sh           # Streaming tmux pane + iTerm2 lifecycle
│       ├── export.sh            # Markdown export
│       ├── jobs.sh              # Background job store
│       ├── keys.sh              # API key resolution (XAI_API_KEY ↔ GROK_API_KEY)
│       ├── prompts.sh           # Template loading + {{VAR}} interpolation
│       ├── providers.sh         # Discovery + CLI-prefers-API policy + vendor display
│       ├── retry.sh             # Retry with backoff
│       ├── roles.sh             # Role management
│       ├── tokens.sh            # Reasoning-model token-cap bumping
│       └── verbosity.sh         # Response verbosity directives
├── skills/
│   ├── council-execution/
│   │   └── SKILL.md             # Standard query execution
│   ├── deep-execution/
│   │   ├── SKILL.md             # Agent-enhanced execution (--agents)
│   │   └── agent-prompt-template.md  # Subagent prompt template
│   └── provider-integration/
│       ├── SKILL.md             # Adding providers guide
│       └── api-patterns.md      # API integration patterns
├── tests/
│   ├── run_tests.sh             # Test runner
│   ├── test_helper.bash         # Shared test utilities
│   ├── fixtures/
│   │   └── fake-clis.bash       # Fake codex/gemini binaries on PATH
│   ├── agent-analysis.bats
│   ├── cache.bats
│   ├── check-status.bats
│   ├── cli-providers.bats       # CLI providers (codex, gemini-cli)
│   ├── display.bats
│   ├── fake-clis.bats
│   ├── format-output.bats
│   ├── jobs.bats
│   ├── keys.bats
│   ├── prompts.bats
│   ├── roles.bats
│   ├── stop-gate.bats
│   ├── tokens.bats
│   ├── verbosity.bats
│   └── query-council.bats
├── LICENSE
├── README.md
└── TESTING.md
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_API_KEY` | - | Google AI Studio key |
| `OPENAI_API_KEY` | - | OpenAI API key |
| `XAI_API_KEY` | - | xAI API key (preferred) |
| `GROK_API_KEY` | - | xAI API key (legacy alias; `XAI_API_KEY` wins if both set) |
| `PERPLEXITY_API_KEY` | - | Perplexity API key |
| `{PROVIDER}_MODEL` | varies | Model override (API providers) |
| `CODEX_MODEL` | gpt-5.5 | Model passed to `codex exec -m` |
| `GEMINI_CLI_MODEL` | gemini-3-flash-preview | Model passed to `gemini -m` |
| `COUNCIL_MAX_TOKENS` | 2048 | Max response tokens |
| `COUNCIL_MAX_RETRIES` | 3 | Retry attempts |
| `COUNCIL_RETRY_DELAY` | 1 | Initial retry delay (s) |
| `COUNCIL_TIMEOUT` | 300 | Request timeout (s) |
| `COUNCIL_CACHE_DIR` | .claude/council-cache | Cache location |
| `COUNCIL_CACHE_TTL` | 3600 | Cache lifetime (s) |
| `COUNCIL_JOBS_DIR` | per-workspace under `$CLAUDE_PLUGIN_DATA` | Background job state location |
| `COUNCIL_MAX_JOBS` | 20 | Terminal-status jobs kept before pruning |
| `COUNCIL_PROMPTS_DIR` | prompts/ | Prompt template location |
| `COUNCIL_DEBUG` | - | Enable debug output |
| `COUNCIL_NO_PANE` | - | Set to `1` to disable the streaming tmux pane globally |
| `COUNCIL_THEME` | auto-detected | Force pane emphasis palette: `light` / `dark` (else OSC 11 query, then `COLORFGBG`, else attribute-only emphasis) |
| `COUNCIL_AUTO_CLOSE` | - | Set to `1` to auto-close the pane on completion (skip the keypress wait); used by tests/demos |
| `COUNCIL_ATTENTION_THRESHOLD` | 2000 | iTerm2 dock-bounce threshold in ms (only triggers if total elapsed >= this) |
| `COUNCIL_VERBOSITY` | standard | Response style: `brief` / `standard` / `detailed` (prepended to all providers' system prompts) |
| `OPENAI_REASONING_EFFORT` | medium | Reasoning model effort |
| `PERPLEXITY_RECENCY` | - | Search recency filter |
