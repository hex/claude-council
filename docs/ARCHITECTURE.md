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
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+ +---------+
   | gemini | |open | | grok | |perp | | kimi | |  codex    | | anti-   |
   |  .sh   | | .sh | |  .sh | |.sh  | |  .sh | |   .sh     | |grav .sh |
   +--------+ +-----+ +------+ +-----+ +------+ +-----------+ +---------+
   (API)      (API)   (API)    (API)   (API)    (CLI)         (CLI)

         +------------+ +----------+ +----------+ +----------+
         | openrouter | | grok-cli | | kimi-cli | |  ollama  |
         |    .sh     | |   .sh    | |   .sh    | |   .sh    |
         +------------+ +----------+ +----------+ +----------+
         (API, router)  (CLI)        (CLI)        (local)
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
INPUT:  --prompt-file <path>  the prompt; the orchestrator always uses this so a
                              large prompt stays off the argv (see ARG_MAX below)
        --image-file <path>   base64 image, passed only to vision-capable providers
        --image-mime <type>   the image's MIME type (pairs with --image-file)
        $1                    a literal prompt, for direct/manual invocation
OUTPUT: stdout = AI response text
EXIT:   0 = success, non-zero = failure (error to stderr)
        3 = the requested model is unavailable for this key/region — the
            orchestrator's model-fallback wrapper retries with a fallback
            model instead of surfacing the error (see Model Fallback below)
```

Two flavors share the interface:

- **API providers** (`gemini`, `openai`, `grok`, `perplexity`, `kimi`,
  `openrouter`), gated on `{PROVIDER}_API_KEY`, talk to vendor APIs over HTTPS,
  charge per call. `openrouter` is a router rather than a vendor: it forwards to
  whichever upstream serves the id in `OPENROUTER_MODEL`, so its answer travels
  one hop further than the others' and its vendor is a runtime fact, not a
  static one. It is also the one script that can seat more than once: with
  `OPENROUTER_MODELS` set it is discovered as `openrouter-1..N`, one seat per
  listed model. The council's unit of identity is the seat — one header, one
  model label, one cache key, one role — so N models is N seats rather than one
  seat that varies. There is no `openrouter-N.sh`: `provider_script_path` routes
  every numbered seat back to the one script, and the orchestrator exports
  `COUNCIL_SEAT` so that script can resolve its own model instead of the
  default. `--list-default-models` reports the default set with each name paired
  to its model, which is the only way a caller outside the library can label a
  numbered seat — the name alone does not say which model it carries. Without that the three seats would post one model behind three
  headers each claiming a different one.
- **CLI providers** (`codex`, `antigravity`, `grok-cli`, `kimi-cli`), gated on the
  binary being on `PATH`, use the user's existing CLI subscription auth, no per-call
  cost. When both an API and CLI sibling exist (codex+openai, antigravity+gemini,
  grok-cli+grok, kimi-cli+kimi), the orchestrator prefers the CLI by default; explicit
  `--providers` wins over the policy. If a CLI provider fails at query time, the
  council retries through its API sibling (when that key is set) and marks the
  slot as a fallback.
- **`ollama`**, also gated on the binary being on `PATH`, but local and keyless:
  it shadows nothing, has no API sibling, and costs nothing per call.

Environment-based configuration:
- `{PROVIDER}_API_KEY` - Required authentication for API providers
- `{PROVIDER}_MODEL` - Model override (also applies to CLI providers via
  `CODEX_MODEL` / `ANTIGRAVITY_MODEL` / `GROK_CLI_MODEL` / `KIMI_CLI_MODEL`)
- `COUNCIL_MAX_TOKENS` - Response length limit (API providers only; `ollama`
  raises its own base to 4096)
- `COUNCIL_DEBUG` - Enable verbose logging

### Vision / Image Input (`--image`)

A single image can be attached with `--image=path` (png/jpg/jpeg/webp/gif,
≤10 MB). `query-council.sh` validates it once at the edge, base64-encodes it to a
temp file, and folds only its SHA-256 into the cache key (`COUNCIL_IMAGE_HASH`) —
the bytes never enter the prompt string.

Per-provider disposition when an image is attached:
- **gemini, openai, grok, perplexity, kimi** (vision-capable) receive the image —
  gemini as an `inlineData` part, openai as `input_image` (Responses API) or
  `image_url` (Chat Completions), grok and perplexity as an OpenAI-compatible
  `image_url` data-URI on their `/chat/completions` endpoint.
- **codex, antigravity, grok-cli, kimi-cli** (CLI, cannot accept an image) route
  to their vision API sibling — codex→openai, antigravity→gemini, grok-cli→grok,
  kimi-cli→kimi — with the image. The route is taken only when the sibling is
  itself vision-capable and its key is set.
- **openrouter** accepts an image on its curated default, which is
  vision-capable. An `OPENROUTER_MODEL` override names one of hundreds of routed
  models whose modalities are not knowable from here, so it is treated as
  text-only until `OPENROUTER_VISION=1` says otherwise.
- **kimi** reads images on its default model. `kimi.sh` has always built the
  OpenAI-shaped `image_url` payload; only the capability table said otherwise,
  which routed images away from a provider that could read them. `kimi-k2` and
  its variants are text-only while `k2.5` and later are not, so a `KIMI_MODEL`
  override opts in with `KIMI_VISION=1`.
- **ollama** answers text-only, prefixed with `(answered without the image)`.

Privacy invariant: only the image's SHA-256 keys the cache. The base64 lives
solely in a temp file passed to providers; it is never written to cache entries
or the saved `council-*.md` transcripts.

### Cache Layer (`scripts/lib/cache.sh`)

```
Cache Key = SHA256("provider:model:verbosity:max_tokens:image_sha256:prompt")
  (verbosity, token cap, and any attached-image hash all bust the cache, so a
   --verbosity or --image change re-queries instead of reusing a stale answer)

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

curl_secret_config(header...):
  - writes the auth header(s) to a mode-600 temp file and echoes its path
  - callers pass it via `curl --config <file>` so API keys never ride the
    process argv (ps-visible) or a URL query string
```

### Model Fallback (`scripts/lib/retry.sh`, `scripts/lib/model_fallback.sh`)

```
is_model_unavailable_error(body):        # retry.sh
  - true only for a 403/404, or a 400 whose message names the model
  - excludes 401/429/5xx: no other model fixes those
  - reads .http_status, stamped onto every >=400 body by ensure_error_body
    (handles xAI's bare-string .error as well as the usual .error.message)

model_fallback_for(provider) -> model    # model_fallback.sh
  - one verified fallback per API provider (openai, grok, gemini, perplexity, kimi)
  - empty for CLI providers, which degrade to their API sibling instead, for
    ollama, whose models are whatever is installed locally, and for openrouter,
    whose fallback id is not yet verified against the live API (so its
    wrong-model-id -> exit 3 mapping errors loudly rather than degrading; the
    mapping is in place for the day a verified id lands)

model_unavailable_cached/remember(provider, model, key_hash):
  - TTL-cached "unavailable" verdict, scoped to provider + preferred model + key
  - written only once the fallback model has actually answered
  - independent of the response cache; tunable via COUNCIL_AVAILABILITY_TTL
```

`query-council.sh`'s `run_provider_with_model_fallback` wraps a provider
script: a preferred-model exit 3 (see Provider Scripts below), or a cached
verdict, retries once with the fallback. The substitution is reported on the
response header, on stderr, and folded into the synthesis prompt.

### The Empty Answer (every API provider)

A provider that returns no visible text is an error even when HTTP says the
call succeeded, so every API seat guards on whitespace-stripped emptiness
rather than `-z`: the council would otherwise cache a model that answers with
a single space and weigh it in the synthesis like any other vote.

This case never reaches the machinery above. `ensure_error_body` stamps a message
and `.http_status` onto every body of 400 or worse, and `retry_error_body`
covers timeout and network, so an empty answer that reaches the error branch
with no top-level `.error` arrived as a 2xx. Three unrelated failures look
identical there, and each seat names them from its own response shape rather
than printing one word for all three:

```
gemini.sh:      .promptFeedback.blockReason  -> "prompt blocked (X)"
                .candidates[0].finishReason  -> "empty response (finishReason: X,
                                                 thoughts tokens: N/M)"

openrouter.sh:  .choices[0].error            -> "provider error (502): ..."
                                                (a mid-generation upstream
                                                failure; OpenRouter answers 200
                                                and puts the error on the choice)
                .choices[0].finish_reason    -> "empty response (finish_reason: X,
                                                 native: Y, reasoning tokens: N/M,
                                                 reasoning chars: K)"
```

`reasoning chars` counts an answer the upstream left in `.message.reasoning`
instead of `.content`; `finish_reason: length` with reasoning tokens near the
completion total means the budget went to thinking. Under `COUNCIL_DEBUG`,
`openrouter.sh` also dumps the raw body on this branch as the catch-all for a
shape not listed here.

Every `.error` read branches on `(.error | type)` before indexing. A bare-string
`.error` (xAI at the top level, some upstreams on the choice) raises in jq
rather than yielding null, `//` does not catch a raise, and jq's postfix `?`
binds only to the term before it, so `.error?.message` still raises. Under
`set -eo pipefail` that kills the script before it prints anything at all.

### Role System (`scripts/lib/roles.sh`)

```
config/roles.json defines:
  - Individual roles (security, performance, etc.)
  - Role presets (balanced, security-focused, etc.)

Role injection prepends instructions to prompt:
  "As a [ROLE], focus on [CONCERNS]..."

Assignment: a bare --roles list is positional (role[i] -> provider[i] in
discovery order); provider=role pairs bind by name. The two forms cannot mix,
and a pair naming an absent provider, or one provider twice, is refused.
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
schemas/agent-analysis.schema.json is the deep-execution analyst's
reply contract. The workflow that runs the analysts enforces it as
their structured output: a reply that does not match is sent back
to the analyst, and one that never arrives is absent from the
result, never silently dropped. validate-analysis.sh mirrors the
schema executably with jq, listing every violation; the bats suite
keeps the two in sync.
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
        one Workflow: N analyst agents in parallel
        (schema-enforced structured output, resumable)
             |
    +--------+--------+--------+--------+
    |        |        |        |        |
    v        v        v        v        v
 Analyst: Analyst: Analyst: Analyst:  ...
 Gemini   OpenAI   Grok     Perplexity
    |        |        |        |
    | Each analyst independently:
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

Key difference from standard mode: the analysts do meaningful analytical
work beyond the API call, pre-digesting each response before synthesis. The
Workflow returns validated objects, so no analysis passes through the
orchestrator's context as text to be pasted and checked; a killed run resumes
with the finished analysts served from cache.

### Local Council Mode (--local / no providers)

```
User -> ask.md (--local, or accepts the offer when no providers found)
             |
        skill asks how many members (unless --roles given); local_council_roles
        resolves that many from a diverse order (default 4, up to 8)
             |
        spawn one general-purpose subagent per role (background, blind to each other)
        (Agent fan-out, not a Workflow: members return display-verbatim markdown
         with nothing to enforce, and this is the no-keys path, so it keeps
         the smaller tool requirement)
             |
    +--------+--------+--------+
    |        |        |        |
    v        v        v        v
 Member:  Member:  Member:  Member:
 devil    simplicity security scalability
    |        |        |        |
    | Each member (Claude, general-purpose subagent):
    | - Answers the role-injected question on its own
    | - Returns Position / Key points / Risks & blind spots / Confidence
    |        |        |
    +--------+--------+
             |
        orchestrator collects all perspectives
             |
        honest synthesis (angles, NOT consensus):
        - shared starting points to pressure-test
        - genuine tensions between roles
        - cross-member blind spots
             |
        save to council-cache
```

Key difference from agent mode: members do **not** call any provider — each one
*is* the answerer (Claude under a role). Because they share a model, the
synthesis is framed around independent angles and blind-spot coverage, never as
cross-vendor consensus. This is the zero-provider fallback so the plugin is
usable on a Claude subscription alone.

## File Structure

```
claude-council/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── .github/
│   └── workflows/
│       └── tests.yml            # bats on ubuntu, macos and windows; shellcheck blocks a merge
├── agents/
│   └── council-advisor.md       # Proactive suggestions
├── commands/
│   ├── ask.md                   # Main /ask command
│   ├── result.md                # /result — fetch/list/cancel background jobs
│   └── status.md                # /status command
├── config/
│   └── roles.json               # Role definitions
├── docs/
│   ├── ARCHITECTURE.md          # This file
│   └── images/
│       └── council-pane.png   # README screenshot of a five-provider run
├── hooks/
│   └── hooks.json               # Stop hook registration (stop gate)
├── prompts/
│   ├── role-injection.md        # {{VAR}} template for role-wrapped prompts
│   ├── synthesis.md             # Synthesis structure + calibration rules
│   ├── stop-review-gate.md      # Stop-gate reviewer contract
│   └── kimi-cli-agent.md        # No-tools agent definition passed to the kimi CLI
├── schemas/
│   └── agent-analysis.schema.json  # Deep-execution analyst reply contract
├── scripts/
│   ├── query-council.sh         # Main orchestrator
│   ├── run-council.sh           # Query + format pipeline, sync and --async
│   ├── format-output.sh         # Terminal formatter
│   ├── check-status.sh          # Provider health check
│   ├── stop-review-gate.sh      # Opt-in Stop hook reviewer
│   ├── validate-analysis.sh     # Executable mirror of the agent-analysis schema (test suite)
│   ├── release.sh               # Version bump and tagging
│   ├── dev/
│   │   └── demo-pane.sh         # Visual test harness for the streaming pane
│   ├── providers/
│   │   ├── gemini.sh            # API
│   │   ├── openai.sh            # API
│   │   ├── grok.sh              # API
│   │   ├── perplexity.sh        # API
│   │   ├── kimi.sh              # API (Moonshot)
│   │   ├── openrouter.sh        # API (router; any model on openrouter.ai)
│   │   ├── codex.sh             # CLI (subscription auth, shadows openai)
│   │   ├── antigravity.sh       # CLI (subscription auth, shadows gemini)
│   │   ├── grok-cli.sh          # CLI (subscription auth, shadows grok)
│   │   ├── kimi-cli.sh          # CLI (subscription auth, shadows kimi)
│   │   └── ollama.sh            # Local (no key, no sibling)
│   └── lib/
│       ├── cache.sh             # Caching utilities
│       ├── deadline.sh          # Wall-clock bound for a command (no GNU timeout on macOS or Git Bash)
│       ├── display.sh           # Streaming tmux pane + iTerm2 lifecycle
│       ├── export.sh            # Markdown export
│       ├── hash.sh              # Portable SHA-256 helper (shasum / sha256sum)
│       ├── jobs.sh              # Background job store
│       ├── keys.sh              # API key resolution (XAI_API_KEY ↔ GROK_API_KEY)
│       ├── model_fallback.sh    # Fallback model per provider + TTL-cached unavailable verdicts
│       ├── pane-watcher.sh      # Runs in the tmux pane: streams status + rendered responses, re-renders them all on resize, offers a retry of failed providers
│       ├── prompts.sh           # Template loading + {{VAR}} interpolation
│       ├── providers.sh         # Discovery, CLI-prefers-API policy, vendor display, model resolution from each CLI's own config
│       ├── render.pl            # Dependency-free markdown renderer (perl fallback)
│       ├── render.py            # Council-tuned Rich markdown renderer
│       ├── retry.sh             # Retry with backoff + off-argv secret config
│       ├── roles.sh             # Role management
│       ├── tokens.sh            # Reasoning-model token-cap bumping
│       └── verbosity.sh         # Shared system prompt, inline-answer guard, verbosity directives
├── skills/
│   ├── council-execution/
│   │   └── SKILL.md             # Standard query execution
│   ├── deep-execution/
│   │   ├── SKILL.md             # Agent-enhanced execution (--agents)
│   │   └── agent-prompt-template.md  # Analyst prompt: query, judge, follow up, structured analysis
│   ├── local-council-execution/
│   │   ├── SKILL.md             # Local Claude-only council (--local / no providers)
│   │   └── agent-prompt-template.md  # Council-member prompt template
│   └── provider-integration/
│       ├── SKILL.md             # Adding providers guide
│       └── api-patterns.md      # API integration patterns
├── tests/
│   ├── run_tests.sh             # Test runner
│   ├── test_helper.bash         # Shared test utilities
│   ├── fixtures/
│   │   ├── fake-clis.bash       # Fake codex/agy/grok/kimi/ollama binaries on PATH
│   │   └── status-fakes.bash    # Recording curl + jq for the check-status tests
│   ├── agent-analysis.bats
│   ├── argmax.bats              # ARG_MAX marshalling round-trip guards
│   ├── cache.bats
│   ├── check-status.bats
│   ├── check-status-probe.bats  # The probes themselves: endpoints, --max-time, keys off the argv
│   ├── cli-providers.bats       # CLI providers (codex, antigravity, grok-cli, kimi-cli, ollama)
│   ├── deadline.bats            # run_with_deadline: stdin passthrough, own status, 143 at the deadline
│   ├── display.bats
│   ├── export.bats
│   ├── fake-clis.bats
│   ├── format-output.bats
│   ├── image.bats               # Vision / --image routing + privacy guards
│   ├── jobs.bats
│   ├── keys.bats
│   ├── model_fallback.bats      # Classifier, fallback pairs, verdict cache, gated real-API test
│   ├── pane-watcher.bats
│   ├── prompts.bats
│   ├── providers.bats           # API provider payloads + secret hygiene
│   ├── release.bats
│   ├── retry.bats
│   ├── roles.bats
│   ├── router-seats.bats        # OPENROUTER_MODELS -> openrouter-1..N, one script, many seats
│   ├── stop-gate.bats
│   ├── theme.bats
│   ├── tokens.bats
│   ├── verbosity.bats
│   └── query-council.bats
├── .shellcheckrc               # Points shellcheck at the sourced libs
├── CHANGELOG.md
├── LICENSE
├── README.md
└── TESTING.md
```

## Configuration Reference

| Variable | Default | Description |
|----------|---------|-------------|
| `GEMINI_API_KEY` | - | Google AI Studio key |
| `GEMINI_THINKING_BUDGET` | - | Cap on Gemini's internal reasoning tokens (`thinkingConfig.thinkingBudget`); unset, the model decides. Keeps room for the visible answer when reasoning would consume the whole `maxOutputTokens` and return an empty 200 |
| `OPENAI_API_KEY` | - | OpenAI API key |
| `XAI_API_KEY` | - | xAI API key (preferred) |
| `GROK_API_KEY` | - | xAI API key (legacy alias; `XAI_API_KEY` wins if both set) |
| `PERPLEXITY_API_KEY` | - | Perplexity API key |
| `OPENROUTER_API_KEY` | - | OpenRouter API key |
| `KIMI_API_KEY` | - | Moonshot/Kimi API key; the only var that makes `kimi` discoverable |
| `MOONSHOT_API_KEY` | - | Read as a fallback by `kimi.sh`, but does not satisfy discovery |
| `{PROVIDER}_MODEL` | varies | Model override (API providers) |
| `CODEX_MODEL` | (unset) | Model passed to `codex exec -m`, only when set (else the codex CLI's own configured model) |
| `ANTIGRAVITY_MODEL` | (unset) | Model passed to `agy --model`, only when set (else the model selected in the Antigravity app) |
| `GROK_CLI_MODEL` | (unset) | Model passed to `grok -m`, only when set (else the grok CLI's own default) |
| `KIMI_CLI_MODEL` | (unset) | Model passed to `kimi -m`, only when set (else the kimi CLI's own configured model) |
| `OPENROUTER_MODEL` | `anthropic/claude-sonnet-5` | Any id from openrouter.ai/models (single seat) |
| `OPENROUTER_MODELS` | (unset) | Comma-separated ids; each becomes a seat `openrouter-N`, replacing the single seat |
| `OPENROUTER_<N>_MODEL` | (unset) | Overrides roster seat N's entry, as `<PROVIDER>_MODEL` does for any provider; the exit-3 degrade path sets it so a roster entry never resends the model that just failed |
| `COUNCIL_SEAT` | (set by the orchestrator) | Which seat a provider script is running as; only the router reads it |
| `OPENROUTER_VISION` | (unset) | Set to `1` to declare an `OPENROUTER_MODEL` override image-capable |
| `KIMI_VISION` | (unset) | Set to `1` to declare a `KIMI_MODEL` override image-capable |
| `COUNCIL_AGENT_MODEL` | `sonnet` | Model the `--agents` ANALYSTS run on (`sonnet`/`opus`/`haiku`/`fable`); not a provider model |
| `OLLAMA_MODEL` | (unset) | Local model id; when unset, whichever model `ollama list` shows first |
| `OLLAMA_HOST` | http://localhost:11434 | Ollama server, following Ollama's own convention |
| `COUNCIL_PROVIDERS` | (unset) | Comma-separated roster queried by default, ahead of discovery; `--providers` still wins per call |
| `COUNCIL_ARGV_LIMIT` | 24000 | Prompt length past which `antigravity` writes the question to a file and points `agy` at it, since Windows caps a command line at 32k |
| `COUNCIL_MAX_TOKENS` | 2048 | Max response tokens (`ollama` uses a 4096 base) |
| `COUNCIL_MAX_RETRIES` | 3 | Retry attempts |
| `COUNCIL_RETRY_DELAY` | 1 | Initial retry delay (s) |
| `COUNCIL_TIMEOUT` | 300 | Per-request timeout for API providers (s); set explicitly it also overrides the CLI bound |
| `COUNCIL_CLI_TIMEOUT` | 1200 | Bound for a CLI provider run (s). Higher because CLI providers get one attempt while API providers retry, so a shared value would be `COUNCIL_MAX_RETRIES + 1` times stricter for a CLI |
| `COUNCIL_CACHE_DIR` | .claude/council-cache | Cache location |
| `COUNCIL_CACHE_TTL` | 3600 | Cache lifetime (s) |
| `COUNCIL_AVAILABILITY_TTL` | 86400 | Model-unavailable verdict cache lifetime (s); `0` re-checks every query |
| `COUNCIL_JOBS_DIR` | per-workspace under `$CLAUDE_PLUGIN_DATA` | Background job state location |
| `COUNCIL_MAX_JOBS` | 20 | Terminal-status jobs kept before pruning |
| `COUNCIL_PROMPTS_DIR` | prompts/ | Prompt template location |
| `COUNCIL_DEBUG` | - | Enable debug output |
| `COUNCIL_NO_PANE` | - | Set to `1` to disable the streaming tmux pane globally |
| `COUNCIL_RENDERER` | auto | `perl` forces the built-in perl renderer; otherwise the pane prefers Rich when a Rich-capable Python exists (python3 with a modern rich, else `uv run --no-project --with rich`), with perl as the fallback |
| `COUNCIL_RICH_PROBE_TIMEOUT` | 10 | Seconds before the pane-open uv probe for Rich is abandoned (guards against a cold uv cache on a dead network stalling pane opening) |
| `COUNCIL_THEME` | auto-detected | Force pane render palette (emphasis + muted text): `light` / `dark` (else OSC 11 query; `COLORFGBG` only asserts `light`, never `dark` since it goes stale; otherwise attribute-only emphasis that inherits the foreground, and muted text keeps faint/bright-black) |
| `COUNCIL_AUTO_CLOSE` | - | Set to `1` to auto-close the pane on completion (skip the keypress wait); used by tests/demos |
| `COUNCIL_RETRY_WAIT` | 45 | Seconds the pane's offer to retry failed providers stays open; the run waits for the answer. `0` disables the offer; `--async` workers default to `0` |
| `COUNCIL_ATTENTION_THRESHOLD` | 2000 | iTerm2 dock-bounce threshold in ms (only triggers if total elapsed >= this) |
| `COUNCIL_VERBOSITY` | standard | Response style: `brief` / `standard` / `detailed` (prepended to all providers' system prompts) |
| `OPENAI_REASONING_EFFORT` | medium | Reasoning model effort |
| `PERPLEXITY_RECENCY` | - | Search recency filter |
