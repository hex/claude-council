# Using the council

Every workflow the council supports, with examples. The [README](../README.md) has install and the first run; [REFERENCE.md](REFERENCE.md) has every flag, variable and default.

## Slash Commands

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

## Specialized Roles

Assign different perspectives to each provider for more comprehensive reviews:

```bash
# Use specific roles
/claude-council:ask --roles=security,performance,maintainability "Review this auth code"

# Use a preset
/claude-council:ask --roles=balanced "Review this implementation"

# Bind a role to a named provider instead of a position
/claude-council:ask --roles=openrouter-2=security,perplexity=devil "Review this design"
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

A bare list is **positional**: the first role goes to the first provider
discovery returns, the second to the second, and so on. That is fine for a fixed
roster and fragile for a growing one — adding a provider script shifts every
later provider's role by one, and reordering `OPENROUTER_MODELS` reassigns which
router seat plays which part. Both happen silently, because only non-empty roles
are printed.

`provider=role` pairs bind a role to a provider's id, so a new provider script
no longer shifts it. A router seat's id is its number, so reordering
`OPENROUTER_MODELS` still hands `openrouter-2`'s role to whichever model is now
second. The two forms
cannot be mixed in one `--roles` (a bare entry alongside a keyed one is
ambiguous); a pair naming a provider that is not being queried, or naming one
provider twice, is refused rather than resolved; and any provider left without a
role is named on stderr:

```
Note: no role for openai grok
```

## Debate Mode

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

## Agent-Enhanced Analysis (--agents)

For complex decisions where deeper analysis justifies the extra time and cost, `--agents` runs
one Workflow of parallel Claude analyst agents that each independently query, evaluate, and
analyze their provider's response before the orchestrator synthesizes everything. Each analysis
is returned as schema-enforced structured output, and an interrupted run can be resumed with the
finished analysts served from cache. Needs a Claude Code with the Workflow tool.

```bash
# Explicit flag
/claude-council:ask --agents "Should we migrate from REST to GraphQL? What are the tradeoffs?"

# Combine with other flags
/claude-council:ask --agents --roles=security,scalability --providers=gemini,openai "Review this auth architecture"
```

**What each analyst does (beyond a simple API call):**
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

**Cost and performance implications**: Agent mode runs one Claude analyst agent per provider,
so Claude usage grows with the size of the council, and an analyst that retries or asks a
follow-up adds provider calls and time on top of the standard run. Use it for high-stakes
decisions, not quick questions.

| | Standard (default) | Agent-enhanced (--agents) |
|---|---|---|
| Claude contexts | 1 | 1 + one analyst per provider |
| Provider calls | One per provider | One per provider, more when an analyst retries or follows up |
| Analysis depth | Raw responses + synthesis | Pre-analyzed + enhanced synthesis |
| Best for | Quick questions, factual queries | Architecture decisions, security reviews, complex tradeoffs |

## Local Council (--local)

If you have no provider keys and no `codex` / `agy` / `grok` / `kimi` / `cursor-agent` CLI and no
`ollama` installed, you can still convene a council, locally, using Claude alone:

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

## Quiet Mode

Get just the bottom line without individual provider responses:

```bash
/claude-council:ask --quiet "Should I use Redis or Memcached?"
```

Quiet mode still queries all providers and analyzes their responses, but only shows the synthesis with consensus/divergence analysis. Use when you want a quick answer without scrolling through multiple perspectives.

## Stated vs Assumed

Providers are given a description of your problem and never the system itself,
so they cannot test a premise your question asserts — they will reason from it
correctly, and agree with each other while doing it. A wrong assumption
therefore produces confident unanimity, which is the hardest failure to spot.

Before the question goes out, the council checks the claims it can check here
and labels the rest:

```
OBSERVED: four sessions logged this failure, confirmed in .cs/memory/
NOT VERIFIED: that the error text carries the tokens those notes are keyed on
```

A provider told "I have not checked whether X holds" can answer "then check X
first". One told "X holds" never will. If the answer turns mainly on facts
living on your disk, establish those first — a single agent that can read the
filesystem beats five that cannot.

## Auto-Context Injection

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

## Image Input

Attach one image (e.g. a UI screenshot) so vision-capable providers can critique it:

```bash
/claude-council:ask --image=shot.png "Why does this dialog render off-center?"
```

- Single image per query, raw size up to 10 MB, extensions: png / jpg / jpeg / webp / gif.
- `gemini`, `openai`, `grok`, `perplexity`, `kimi` and `openrouter` (on its default model) receive the image alongside the prompt.
- CLI providers answer through their vision sibling: `codex` via `openai`, `antigravity` via `gemini`, `grok-cli` via `grok`, `kimi-cli` via `kimi` (the slot is marked as a fallback, with the reason `<cli> cannot read images; the <sibling> API answered with the image`). If the sibling is unusable (no API key), not vision-capable, or already answering in its own slot, the CLI provider answers text-only instead and its answer is prefixed with `(answered without the image)`. Selecting `ollama`, `cursor-cli`, `claude-cli` or `copilot-cli` directly is text-only.

Privacy: the image is sent to the providers that can see it, but its bytes are **not** written to cache entries or the saved `council-*.md` transcripts — only a hash of the image keys the cache.

## Export to File

Save council responses as clean markdown files for documentation or sharing:

```bash
/claude-council:ask --output=docs/decision.md "Should we use REST or GraphQL?"
```

The exported file includes:
- Metadata header (query, date, providers)
- Each provider's full response
- Synthesis with consensus/divergence analysis

## Background Jobs (--async)

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

## Asking about the conversation itself

`/claude-council:ask` sends a question you typed. `/claude-council:advise` sends
a bounded slice of the current conversation, so providers see the reasoning
rather than your summary of it. A model given only your framing tends to agree
with your framing.

```bash
# Ask the council about the approach taken so far
/claude-council:advise "are we solving the right problem here?"

# Narrow the window
/claude-council:advise --turns=last:10 "what did we miss?"
```

Every run resolves this session's transcript, digests it, and shows the byte
size, the turn count and the opening lines before asking whether to send. The
digest carries human turns, assistant replies, and each AskUserQuestion exchange
as the question, its options, and the pick; it excludes every other tool result
and tool input, thinking blocks, hook output, and messages from other sessions.
The script skips a damaged record inside the transcript, counts it, and writes
the count into the digest itself, so an incomplete digest says so where both
the user and the providers read it.

The confirmation is the privacy control, and deliberately so: a script cannot
tell whose conversation it holds, because inside a subagent the ambient session
id names the parent conversation.

## Proactive Agent

The `council-advisor` agent will suggest consulting the council when:
- Discussing architecture or design decisions
- Stuck debugging after multiple failed attempts

## Verbosity

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

## Stop-Gate Review (opt-in, off by default)

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
(or set `"enabled": false`) to turn it off. The reviewer is any provider
script under `scripts/providers/`, `claude-cli` and `copilot-cli` included; a
name that is not one allows every stop without a review or a message. A
`copilot-cli` reviewer spends a premium request per stop.

Privacy: the review sends your full uncommitted `git diff` to the configured
provider, named by its provider id. With `ollama` it never leaves the machine.
A CLI provider (`codex`, `antigravity`, `grok-cli`, `kimi-cli`, `cursor-cli`) sends
it to that CLI's vendor under your subscription rather than an API key, and an
API provider (`gemini`, `openai`, `grok`, `perplexity`, `kimi`) sends it to that
third-party API — `kimi` sends it to Moonshot. `openrouter` is the one seat that
discloses twice: to OpenRouter, and onward to whichever upstream serves the model
id you pinned. Keep the reviewer on `ollama` if your working tree may
contain secrets.

## Heads-up side-check (opt-in, off by default)

While Claude works a long turn inside Claude Code, a council seat can reread
the conversation and surface one thing you may have missed: a trade-off nobody
called out, a result that looks off. It needs the council-pane mod (Claude Code
with `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`, 2.1.302 or later) and one of two
switches. The `/config` row "Heads-up side-check" turns it on in every project.
A project file turns it on, or off, for that project alone and picks the seats
and cadence:

```bash
cat > .claude/council-heads-up.json <<'EOF'
{"enabled": true, "seats": ["codex"], "every": 3}
EOF
```

`enabled` is optional: `true` turns the check on here, `false` turns it off
here whatever the row says, and without it the row decides. `seats` is the
order asked, first answer that is not NONE wins, no synthesis; it defaults to
`["codex"]`. `every` is model requests per check inside a turn, default 3, so
a check runs at the third, sixth, ninth request. Either switch is the consent:
nothing asks before a check sends.

The note sits above the prompt:

```
✦ Heads up · The migration test passed against the empty fixture DB, so the backfill path never ran.
  1: Learn more   2: Knew this already   0: Dismiss      codex · gpt-6.1-sol · 12.4 KB · 27 s
```

`1` opens the note as the builtin draws it, a bold title and three to six
bullets with the action last, and offers `1: Tell Claude` and `0: Close`; tell
Claude puts a draft quoting the note in your prompt box, and you send or edit it.
`2` and `0` record the topic so no seat raises it again. Typing a prompt while a
note shows counts as typing past it, and that many later checks are skipped.
Claude never sees a note you did not tell it about.

`/heads-up setup` asks in Claude Code's own dialog: where the check runs
(this project, every project, or off here), which seats reread the turn (the
providers with a CLI on PATH or a key in your environment, up to four; type
any other list under Other), how often, then for each seat which model (its
current one, codex's catalog, or one you type) and for codex how hard to think;
then it writes the project file, and sets the `/config` row for "every
project". By hand, the picks live under `models`: `"models": {"codex":
{"model": "gpt-6.1-sol", "effort": "high"}, "gemini": {"model":
"gemini-2.5-pro"}}`; a model goes to that provider's own `*_MODEL` variable for
the check, an effort only to codex. A seat gets 60 seconds per check (`COUNCIL_HEADS_UP_SEAT_SECONDS`), so a slow CLI such as antigravity, which the council itself allows twenty minutes, times out here; pick codex, gemini or another fast seat. `/heads-up on`
and `/heads-up off` write the project file for you, keeping its seats and
cadence; `/heads-up on gemini,grok-cli` names the seats to ask, any provider
the council runs, in the order asked. `/heads-up` alone (or `/heads-up
status`) says whether the
check is on here and which switch set it, then the counts kept on this machine
and never sent anywhere: checks run, with how many found nothing, drew a note,
repeated a topic already seen, or failed; and the presses, learn, tell, knew,
dismiss and typed past. A check that found nothing leaves a dim receipt on the
hint under the prompt, `heads-up: gemini read 8.3 KB in 11 s, nothing to flag`,
until you type or the next check; only a failed check writes a transcript row. The first session on a machine where the check is off
adds a dim tip to the hint under the empty prompt, `Tip: /heads-up on lets
another model watch long turns and flag what Claude missed`, until you type; a
flag in the plugin store keeps it from coming back.

Privacy: unlike `/claude-council:advise`, nothing asks before a send. Each
check digests the last five turns of this session's transcript plus the last
eight tool results inside them, cut to 2,000 characters each, and sends that
to the seats in order until one answers. Tool results can carry what a command
printed, a secret included; messages from other sessions, hook output and
thinking never go. Each check logs or shows the bytes sent and the seat that
answered. The seat rules under Stop-gate review above apply: `ollama` keeps it
on the machine, a CLI seat sends it to that vendor under your subscription,
`openrouter` discloses twice.

Environment: `COUNCIL_HEADS_UP_SEAT_SECONDS` (per seat, default 60),
`COUNCIL_HEADS_UP_RUN_SECONDS` (per check, default 180),
`COUNCIL_HEADS_UP_TURNS` (default 5) and `COUNCIL_HEADS_UP_RESULTS` (default
8). A seat that times out or errors passes to the next; a check whose seats all
fail logs one line and shows nothing.

## Specialists (experimental)

A specialist is a Codex agent that Claude can hand a coding task to. It works in
its own git worktree and branch, commits each round there, and you merge or
discard the branch at the end. Claude offers one when a task matches its
use-when and starts it only when you ask or agree.

Specialists live in the Claude Code mod, so they need `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`
and a logged-in `codex`. Run `/specialists` to set one up. Each one has a name, a
Codex model, an effort, a use-when for Claude, and the skills it follows: every
`SKILL.md` you name opens every task it starts. The mod looks for a skill in
`~/.claude/skills`, `~/.codex/skills`, `~/.agents/skills` and its own bundled
`mods/council-pane/specialists/` folder, in that order, and the first folder
with the name wins, so your own copy of a template's skill replaces the bundled one.

The plugin ships no specialists, but the screen offers six templates to start
from: `bug-fixer`, `ci-fixer`, `refactorer`, `test-writer`, `test-pruner` and
`docs-updater`. Each one comes with a full skill of its own. The first session
where specialists can run shows a one-line note about them, once.

The [mod README](../mods/council-pane/README.md#specialists) covers the screen, the
tool calls, the worktrees and the limits.
