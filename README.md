# claude-council

A Claude Code plugin that consults multiple AI coding agents in parallel and shows you their answers side-by-side. Useful when one model's bias could mislead you and the right call depends on cross-checking — architecture decisions, debugging dead ends, security reviews, framework picks.

[Quick start](#quick-start) · [Usage](#usage) · [Configuration](#configuration) · [Reference](#reference) · [Development](#development)

## Quick start

```bash
# 1. Install via Claude Code plugin marketplace
/plugin marketplace add hex/claude-marketplace
/plugin install claude-council

# 2. Configure at least one provider — any of these works:
export OPENAI_API_KEY="..."         # or GEMINI_API_KEY, XAI_API_KEY, PERPLEXITY_API_KEY
                                    # OR install the codex / antigravity (agy) CLIs (uses your existing
                                    # subscription — no API key needed)

# 3. Ask anything
/claude-council:ask "Should I use UUID or BIGINT primary keys for a SaaS users table?"
```

You get side-by-side responses from each configured provider:

```
🔳 Codex - gpt-5.5
   Use UUID primary keys — they avoid enumeration, work across distributed
   services, and survive imports/exports cleanly.

🟦 Antigravity - Gemini 3.5 Flash (High)
   UUIDv7 specifically: security of non-guessable IDs plus the index
   locality of time-ordered sequences.

🟥 Grok - grok-4.20-reasoning
   BIGINT autoincrement — smaller index, faster joins. Handle public-
   exposure concerns with a separate UUID slug column.

🟩 Perplexity - sonar-reasoning-pro
   BIGINT: 25% smaller than UUID, better cache locality, with citations
   to Postgres benchmarks.

## Synthesis
Two providers prefer UUID(v7), two prefer BIGINT. Choice depends on
whether you need distributed ID generation.
```

Inside tmux, results stream into a side pane in real time with vendor-colored banners. Run `/claude-council:status` to confirm what's configured and connected.

## Features

- Query Gemini, OpenAI (GPT/Codex), Grok, and Perplexity simultaneously
- Use the `codex` and `agy` (Antigravity) CLIs (subscription auth) when installed — preferred over their API siblings
- Side-by-side comparison of responses with vendor-colored headers
- Streaming tmux pane that renders responses as they land
- Specialized roles, debate mode, and agent-enhanced deep analysis for high-stakes decisions
- Background jobs (`--async`) for long-running queries, with `/claude-council:result` to fetch, list, and cancel
- Opt-in stop-gate: a second model reviews your uncommitted diff before Claude ends its turn
- Extensible provider system — add new AI agents easily
- Proactive agent that suggests consulting the council on architecture / debugging dead ends

## Installation

### From Marketplace (Recommended)

```bash
# Add the hex-plugins marketplace
/plugin marketplace add hex/claude-marketplace

# Install claude-council
/plugin install claude-council
```

### Manual (run from a local clone)

For normal use, prefer the marketplace or GitHub install above — both persist
across sessions. A manual clone is for running from a local working copy
(development, or offline). Clone the repo **anywhere**, then point Claude Code
at the repo root for the current session:

```bash
git clone https://github.com/hex/claude-council.git
claude --plugin-dir /path/to/claude-council    # repo root; loaded for this session only
```

> **Cloned it and nothing loads?** Two traps to avoid:
> 1. **Don't clone into `~/.claude/plugins/`** (Windows:
>    `%USERPROFILE%\.claude\plugins\`). That's Claude Code's managed install
>    *cache* — it is never scanned for manually-added plugins, so the plugin
>    won't appear in the Installed tab or respond to its slash commands.
> 2. **`pluginDirectories` in `settings.json` does nothing** — it isn't a real
>    setting, so it's silently ignored (no error shown). Use `--plugin-dir`
>    above for a local clone, or install via the marketplace / GitHub for a
>    persistent setup.

## Usage

### Slash Commands

```bash
# Query all configured providers
/claude-council:ask "How should I structure authentication in this Express app?"

# Query specific providers
/claude-council:ask --providers=gemini,openai "What's the best approach for caching here?"

# Include a specific file for review
/claude-council:ask --file=src/auth.ts "What's wrong with this implementation?"

# Attach a screenshot for visual critique
/claude-council:ask --image=shot.png "Why does this dialog render off-center?"

# Export response to markdown file
/claude-council:ask --output=docs/auth-decision.md "How should we implement authentication?"

# Quiet mode - show only synthesis
/claude-council:ask --quiet "What's the best caching strategy?"

# Check connectivity and configured models for each provider
/claude-council:status

# Run a long query in the background, fetch it later
/claude-council:ask --async "Deep-dive the tradeoffs of event sourcing here"
/claude-council:result <job-id>
```

### Quick Reference

| Flag | Description |
|------|-------------|
| `--providers=list` | Query specific providers (e.g., `gemini,openai,codex`) |
| `--roles=list` | Assign roles (e.g., `security,performance` or preset like `balanced`) |
| `--debate` | Enable two-round debate mode |
| `--file=path` | Include specific file in context |
| `--image=path` | Attach one image (e.g. a screenshot) for vision-capable providers |
| `--output=path` | Export response to markdown file |
| `--quiet` | Show only synthesis, hide individual responses |
| `--agents` | Agent-enhanced analysis with subagents (slower, deeper) |
| `--local` | Local Claude-only council when you have no provider keys (see below) |
| `--async` | Detach the query as a background job; fetch with `/claude-council:result` |
| `--no-cache` | Force fresh queries, skip cache |
| `--no-auto-context` | Disable automatic file detection |
| `--no-pane` | Disable streaming tmux pane (default: on inside tmux) |
| `--verbosity=LEVEL` | Response style: `brief` / `standard` / `detailed` |

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

### Agent-Enhanced Analysis (--agents)

For complex decisions where deeper analysis justifies the extra time and cost, `--agents` spawns
parallel Claude subagents that each independently query, evaluate, and analyze their provider's
response before the orchestrator synthesizes everything.

```bash
# Explicit flag
/claude-council:ask --agents "Should we migrate from REST to GraphQL? What are the tradeoffs?"

# Combine with other flags
/claude-council:ask --agents --roles=security,scalability --providers=gemini,openai "Review this auth architecture"
```

**What each subagent does (beyond a simple API call):**
1. Queries the provider
2. Evaluates response quality - did it actually address the question?
3. If the response is vague or off-topic, reformulates and retries
4. Asks follow-up questions to surface deeper insights
5. Extracts structured analysis: key recommendations, confidence level, blind spots

**Enhanced synthesis includes:**
- Confidence-weighted consensus (high-confidence agreement weighted more)
- Cross-provider blind spot analysis
- Divergence with context (why providers disagree)

**Natural language triggers**: The command also detects complex questions automatically.
If your question contains architecture, security review, tradeoff analysis, or similar
signals, you'll be asked whether to enable agent mode.

**Cost and performance implications**: Agent mode spawns one Claude subagent per provider.
This means ~4x more Claude API usage and ~15-25 seconds additional latency compared to
standard mode. Use it for high-stakes decisions, not quick questions.

| | Standard (default) | Agent-enhanced (--agents) |
|---|---|---|
| Speed | ~3-5s | ~15-25s |
| Claude API cost | 1 context | 1 + N providers |
| Provider API cost | Same | Same |
| Analysis depth | Raw responses + synthesis | Pre-analyzed + enhanced synthesis |
| Best for | Quick questions, factual queries | Architecture decisions, security reviews, complex tradeoffs |

### Local Council (--local)

If you have no provider keys and no `codex` / `agy` CLI installed, you can
still convene a council — locally, using Claude alone:

```bash
# Explicit
/claude-council:ask --local "Is event sourcing worth it for this order service?"

# Pick the exact lenses yourself (skips the size prompt)
/claude-council:ask --local --roles=architecture "How should we shard this database?"
```

It spawns several Claude subagents in parallel, each pinned to a different role
and **blind to the others**, then synthesizes their perspectives. When you don't
pass `--roles`, it asks **how many members** to convene (default 4, up to 8) and
fills them from a diverse ordering led by the sharpest lenses (devil's-advocate,
simplicity, security, …). You don't need to pass `--local` explicitly: when a
query finds no configured providers, the command offers a local council instead
of erroring.

> **Honest caveat:** every member is Claude, so they share priors and training.
> Agreement between them is a *shared starting point to pressure-test*, not
> cross-vendor corroboration. The value is independent angles and blind-spot
> coverage — for genuinely independent models, configure a provider key or a CLI
> (`/claude-council:status` shows what's available). The synthesis is framed
> around angles and tensions, not "consensus", to keep this distinction clear.

### Quiet Mode

Get just the bottom line without individual provider responses:

```bash
/claude-council:ask --quiet "Should I use Redis or Memcached?"
```

Quiet mode still queries all providers and analyzes their responses, but only shows the synthesis with consensus/divergence analysis. Use when you want a quick answer without scrolling through multiple perspectives.

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

### Image Input

Attach one image (e.g. a UI screenshot) so vision-capable providers can critique it:

```bash
/claude-council:ask --image=shot.png "Why does this dialog render off-center?"
```

- Single image per query, raw size up to 10 MB, extensions: png / jpg / jpeg / webp / gif.
- `gemini`, `openai`, `grok`, and `perplexity` receive the image alongside the prompt.
- CLI providers answer through their vision sibling: `codex` via `openai`, `antigravity` via `gemini` (the slot is marked as a fallback). If the sibling is unusable (no API key) or already answering in its own slot, the CLI provider answers text-only instead.

Privacy: the image is sent to the providers that can see it, but its bytes are **not** written to cache entries or the saved `council-*.md` transcripts — only a hash of the image keys the cache.

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
- Debate mode round 2 rebuttals are not cached (they depend on round 1 content) — with one exception: if a CLI provider fails in round 2 and falls back to its API sibling, that fallback rebuttal is cached, keyed on the full debate prompt (which already includes the round 1 answers)

Privacy: cache entries and the saved `council-*.md` transcripts store the **full prompt in cleartext** — including any files you pass with `--file` and the auto-included context. Council drops a `.gitignore` (`*`) into the cache dir so these never get committed, but the plaintext still lives on local disk under `COUNCIL_CACHE_DIR` until it ages out or you clear it.

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

### Background Jobs (--async)

Reasoning and deep-research models can take minutes. `--async` detaches the
query as a tracked background job instead of blocking the conversation:

```bash
/claude-council:ask --async "Compare migration strategies for this schema"
# → job id, returned immediately

/claude-council:result              # list jobs
/claude-council:result <job-id>     # fetch a finished result (synthesis included)
/claude-council:result cancel <id>  # terminate a running job
```

Each job persists as a JSON record plus log under a per-workspace state
directory (`$CLAUDE_PLUGIN_DATA`, falling back to tmp). A crashed worker is
marked `failed` automatically; finished jobs are pruned beyond
`COUNCIL_MAX_JOBS` (default 20).

### Proactive Agent

The `council-advisor` agent will suggest consulting the council when:
- Discussing architecture or design decisions
- Stuck debugging after multiple failed attempts

## Configuration

### API Keys

Set environment variables (recommended):

```bash
export GEMINI_API_KEY="your-key"
export OPENAI_API_KEY="your-key"
export XAI_API_KEY="your-key"          # GROK_API_KEY also accepted
export PERPLEXITY_API_KEY="your-key"
```

### CLI Providers (subscription auth, no API key)

If `codex` or `agy` CLIs are installed and on `PATH`, they're discovered automatically and **preferred over their API siblings** by default:

- `codex` (OpenAI Codex CLI) shadows the `openai` API provider
- `antigravity` (Antigravity CLI, `agy`) shadows the `gemini` API provider

CLI providers use your existing CLI subscription — no API key, no per-call cost. To opt back into the API variant for a single call, pass it explicitly: `--providers=openai` or `--providers=gemini`. Listing both API and CLI together (e.g., `--providers=gemini,antigravity`) runs them side-by-side for comparison.

If a CLI provider fails at query time and its API sibling's key is set, the council automatically retries through that API sibling and marks the slot as a fallback (the answer is shown under the CLI slot with the API model's name and a "fell back to … API" note). The fallback is skipped when the sibling is already in your selected providers, so you never get the same vendor's answer twice.

Override CLI model selection (defaults mirror what each CLI picks itself):

```bash
export CODEX_MODEL="gpt-5-codex"                # default: gpt-5.5
export ANTIGRAVITY_MODEL="Gemini 3.1 Pro (High)"  # default: Gemini 3.5 Flash (High)
```

### Verbosity

Shape how providers respond by prepending a directive to their system prompts. Affects style and depth, not just length:

```bash
export COUNCIL_VERBOSITY=brief     # ~3-5 sentences, bullets, no code
export COUNCIL_VERBOSITY=standard  # default — balanced thoroughness
export COUNCIL_VERBOSITY=detailed  # thorough analysis with code + edge cases
```

Or per-call: `--verbosity=brief|standard|detailed`. The slash command also asks via the provider-selection prompt.

| Level | Typical output |
|-------|----------------|
| `brief` | 3-5 sentences max, bullets where possible, skips code blocks unless asked |
| `standard` | Balanced — current default behavior, no directive prepended |
| `detailed` | Thorough — includes code examples, edge cases, trade-offs, and rationale |

### Stop-Gate Review (opt-in, off by default)

A Stop hook can ask one council provider to review your uncommitted `git diff`
before Claude ends its turn, blocking only on a first-line `BLOCK:` verdict.
Enable it per project:

```bash
cat > .claude/council-stop-gate.json <<'EOF'
{"enabled": true, "provider": "codex", "max_iterations": 1}
EOF
```

Safety properties: it never blocks on a clean tree, never re-gates a
continuation already triggered by a stop hook, caps blocks per session at
`max_iterations`, and any reviewer failure allows the stop. Delete the file
(or set `"enabled": false`) to turn it off.

Privacy: the review sends your full uncommitted `git diff` to the configured
provider. With a CLI provider (`codex`, `agy`) it stays within that tool's own
subscription auth; with an API provider (`gemini`, `openai`, `grok`,
`perplexity`) the diff is transmitted to that third-party API. Keep the reviewer
on a local CLI provider if your working tree may contain secrets.

## Reference

Detail-heavy knobs you'll only need occasionally. The defaults are sensible for most workflows.

### Model Selection

Override default models via environment variables:

```bash
export GEMINI_MODEL="gemini-3.1-pro-preview"       # default
export OPENAI_MODEL="gpt-5.5-pro"                   # default
export GROK_MODEL="grok-4.20-reasoning"             # default
export PERPLEXITY_MODEL="sonar-reasoning-pro"       # default (reasoning + search)
```

Response length cap (default: 2048):

```bash
export COUNCIL_MAX_TOKENS=4096  # longer responses
export COUNCIL_MAX_TOKENS=1024  # shorter, faster responses
```

### Reasoning Models

For reasoning models from any provider, the token limit is automatically increased to 8x the base value (minimum 32768). This is because reasoning models combine internal thinking tokens and visible output tokens into a single `max_output_tokens` limit — without the bump, the model can run out mid-response.

The bump applies to:

- **OpenAI**: `codex-*`, `*-codex`, `o3-*`, `o4-*`, `gpt-5.[4-9]*`
- **Gemini**: `gemini-3*`, `*thinking*`
- **Grok**: `*reasoning*`, `grok-4*`, `grok-3-mini-*`, `grok-build-*`
- **Perplexity**: `sonar-reasoning*`, `*deep-research*`

| Model Type | COUNCIL_MAX_TOKENS | Actual Limit |
|------------|-------------------|--------------|
| Standard (gpt-5.1) | 2048 (default) | 2048 |
| Reasoning (gpt-5.5-pro) | 2048 (default) | 32768 |
| Reasoning (gpt-5.5-pro) | 4096 | 32768 |

Control reasoning effort to balance speed vs thoroughness:

```bash
export OPENAI_REASONING_EFFORT="low"     # faster, less reasoning overhead
export OPENAI_REASONING_EFFORT="medium"  # default - balanced
export OPENAI_REASONING_EFFORT="high"    # thorough reasoning, slower
```

Grok's token accounting depends on the model: `grok-build` counts thinking tokens separately, so `max_tokens` caps only its visible output; the other reasoning models (`grok-4*`, `*-reasoning`, `grok-3-mini-*`) share one budget between thinking and output. Either way, council bumps the cap for these models so a long answer isn't cut off mid-response.

### Perplexity Search Features

Perplexity's sonar models are search-augmented, providing web-grounded responses with citations:

```bash
# Filter search results by recency: day, week, month, year
export PERPLEXITY_RECENCY="week"
```

Available models:
- `sonar` - Fast, search-enabled
- `sonar-pro` - More capable, search-enabled
- `sonar-reasoning` - Chain-of-thought reasoning + search
- `sonar-reasoning-pro` - Best reasoning + search (default)

Perplexity is useful when you need current information (latest framework versions, recent best practices) rather than just training-data knowledge.

### Retry & Timeout

Automatic retry on transient failures (429 rate limits, 5xx server errors):

```bash
export COUNCIL_MAX_RETRIES=3    # default: 3 retries
export COUNCIL_RETRY_DELAY=1    # default: 1 second initial delay (doubles each retry)
export COUNCIL_TIMEOUT=300      # default: 300 seconds per request
```

Timeouts fail fast (no retry) to prevent blocking on hung providers.

### Display & Terminal Integration

When run inside tmux, council opens a streaming side pane that shows live provider status (`querying`, `complete`, `cached`, `error` with timing) and renders each response as it lands. Rendering prefers [Rich](https://github.com/Textualize/rich) when a Rich-capable Python is available (`python3` with a modern `rich` installed, or [`uv`](https://docs.astral.sh/uv/), which fetches it on demand): word-wrapped prose, tables fitted to the pane width, syntax-highlighted code, clickable links — styled with your terminal's own palette (cyan headings, yellow code, vendor-colored banners). Without one, a built-in dependency-free perl markdown renderer takes over with the same visual language, so nothing needs to be installed. Press **Esc** to close the pane.

Colors adapt to your terminal theme: the pane detects the background
(OSC 11 query, `COLORFGBG` fallback). The Rich renderer flips its
code-highlighting theme to match; the perl renderer renders bold/italic
emphasis bright on dark themes, dark on light themes, and attribute-only when
undetectable, with muted text (link URLs, table grid lines, `---` rules,
sub-headings, the "waiting on" label) following suit — faint/bright-black on
dark, a readable dark gray on light.
Force it with `COUNCIL_THEME=light` or `COUNCIL_THEME=dark`.

When the outer terminal is iTerm2, council also drives:

- **Tab color** — yellow while querying, green on success, red if any provider errored. Set via `it2setcolor`; ambient state signal without looking at the terminal.
- **Dock attention** — bounces the iTerm2 dock icon when council finishes if the run took longer than `COUNCIL_ATTENTION_THRESHOLD` (default 2000ms). Useful for slow `--debate` queries when you've switched apps.
- **`SetMark` navigation** — emits OSC 1337 SetMark before each provider response inside the pane. Cmd+Shift+↑/↓ in iTerm2 jumps between provider sections.

```bash
export COUNCIL_NO_PANE=1                # disable the streaming pane globally
export COUNCIL_RENDERER=perl             # force the built-in perl renderer
export COUNCIL_ATTENTION_THRESHOLD=5000  # only bounce dock if run > 5s
```

Per-call opt-out via `--no-pane`. iTerm2 features no-op silently outside iTerm2; pane no-ops outside tmux.

## Adding New Providers

See the `provider-integration` skill for guidance on adding new AI providers.

## Direct Script Usage

Use the scripts directly without Claude Code (for automation, CI, or debugging):

```bash
# Basic query - returns JSON
bash scripts/query-council.sh -- "What is dependency injection?"

# With flags
bash scripts/query-council.sh --providers=gemini,openai --roles=balanced -- "Review this pattern"

# Pipe to formatter for terminal display
bash scripts/query-council.sh --providers=gemini -- "Question" 2>/dev/null | bash scripts/format-output.sh

# Check provider status (the Perplexity check makes one minimal billable request,
# since Perplexity has no free /models endpoint to probe)
bash scripts/check-status.sh

# List configured providers (human-readable, with policy info)
bash scripts/query-council.sh --list-available

# List the providers that would be queried by default (machine-readable)
bash scripts/query-council.sh --list-default
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
- Valid API keys for at least one provider, OR `codex` / `agy` (Antigravity) CLI installed
- Optional: a Rich-capable Python (`python3` with a modern `rich`, or `uv`) upgrades the tmux pane's markdown rendering; without it the built-in perl renderer is used

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
bats tests/cli-providers.bats
bats tests/roles.bats
```

CLI-provider paths are tested hermetically: `tests/fixtures/fake-clis.bash`
installs fake `codex`/`agy` executables onto `PATH` whose behavior is
switched via `COUNCIL_FAKE_BEHAVIOR` and which record every invocation, so
provider scripts, async jobs, and the stop gate run end-to-end with no
network and no real CLIs.

See `TESTING.md` for complete test documentation including manual test procedures.

### Release Checklist

1. Make changes
2. Test locally
3. Bump version in `.claude-plugin/plugin.json`
4. Commit and push
5. Users update via `/plugin update claude-council`
