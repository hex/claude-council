---
description: Query multiple AI agents (Gemini, OpenAI, Grok, Perplexity) for diverse perspectives on architecture decisions, technology choices, debugging dead-ends, and security tradeoffs. Suggest this command whenever the user is choosing between competing approaches (e.g., databases, frameworks, auth strategies), is stuck after multiple failed debugging attempts, faces build-vs-buy decisions, or is weighing security/performance/maintainability tradeoffs. Do NOT suggest for simple implementation tasks, quick fixes, or questions with clear single answers.
argument-hint: [--file=path] [--providers=list] [--roles=list] [--verbosity=brief|standard|detailed] [--debate] [--agents] [--local] [--async] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
allowed-tools: Agent, Bash(*), Read, Glob, Grep, AskUserQuestion, TaskCreate, TaskUpdate
---

Query the council of AI coding agents to gather diverse perspectives.

## Progress Tracking

Create a task at the start to show progress throughout the query:

```
TaskCreate:
  subject: "Query council"
  description: "Querying AI providers for diverse perspectives"
  activeForm: "Preparing council query..."

TaskUpdate: status → in_progress
```

Update `activeForm` as you progress through phases:
- `"Gathering context..."` - during auto-context detection
- `"Querying council providers..."` - during query-council.sh execution
- `"Formatting responses..."` - during format-output.sh execution
- `"Synthesizing recommendations..."` - during synthesis generation

Mark `status → completed` when finished.

## Step 0: Local Mode & Provider Availability

Decide up front whether this is a local (Claude-only) council run, before asking
any provider questions:

1. **If `--local` is in $ARGUMENTS → local mode.** Skip the provider and agent
   questions and go straight to "If Local Mode is Active" in Step 2. Local mode
   honors `--roles`, `--file`, `--verbosity`, `--quiet`, and auto-context; it
   ignores `--providers`, `--debate`, `--agents`, and `--async`. When `--roles`
   is not passed, the local-council skill asks the user how many members to
   convene before spawning them.

2. **Otherwise, check what providers are configured:**
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-default 2>&1 | head -1
   ```
   - If this lists one or more providers → continue with the normal flow below.
   - If it is empty or reports `No providers configured` → do NOT hard-fail.
     Offer the local council:
     ```
     AskUserQuestion:
       Question: "No AI providers are configured. Run a local council instead? It's several Claude subagents, each playing a different role — independent angles, but same-model, not cross-vendor."
       Header: "No providers"
       Options:
         - "Run local council (Recommended) - independent Claude perspectives, no API keys needed"
         - "How to add a provider - show what to configure for a real cross-vendor council"
         - "Cancel"
     ```
     - "Run local council" → local mode (Step 2).
     - "How to add a provider" → show the setup hint (set an API key, or install
       the `codex` / `gemini` CLI; `/claude-council:status` shows what's
       available) and stop.
     - "Cancel" → stop.

**Never pass `--local` to query-council.sh or run-council.sh** — it is a
command-layer flag with no meaning to those scripts. Strip it from $ARGUMENTS
before constructing any script invocation.

## Pre-Query Interaction

Before querying, use AskUserQuestion in these scenarios:

### 1. Provider Selection + Verbosity (if --providers and --verbosity not specified)

First, discover the providers that would be queried by default (post CLI-prefers-API policy — `--list-default` is the right flag here, NOT `--list-available`, which includes shadowed API siblings that won't run by default):
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-default 2>&1 | head -1
```

**Only show default-queried providers in the question.** If only 1 provider is available, skip the provider question and use it directly. If the user wants a shadowed API provider (e.g., `openai` when codex is installed), they can pass `--providers=openai` explicitly.

**The first option of the providers question must be "All providers" (Recommended)** — this is the most common choice and saves the user from clicking each provider individually. If the user picks it, treat it as selecting every available provider.

**Combine providers + verbosity into a single AskUserQuestion call** (it supports multiple questions per call) so the user resolves both decisions in one screen instead of two:

```
Question 1: "Which AI providers should I consult?"
Header: "Providers"
multiSelect: true
Options:
  - All providers (Recommended) - query every configured provider in parallel
  - Gemini (gemini-3.1-pro-preview) - Google's reasoning model
  - OpenAI (gpt-5.5-pro) - OpenAI's reasoning model
  - Grok (grok-4.20-reasoning) - xAI's reasoning model
  - Perplexity (sonar-reasoning-pro) - search-augmented reasoning

Question 2: "How verbose should the responses be?"
Header: "Verbosity"
multiSelect: false
Options:
  - Standard (Recommended) - balanced thoroughness
  - Brief - 3-5 sentences, bullets only, no code unless asked
  - Detailed - thorough analysis with code examples and trade-offs
```

When the providers list exceeds 4 options ("All" + N providers), AskUserQuestion's 4-option limit forces a different shape — collapse to "All / Fast subset / Custom" presets.

**Skip the verbosity question if `--verbosity` was passed** explicitly. Skip the providers question if `--providers` was passed. Resolve both via flags when both are present.

Map the verbosity selection to the `--verbosity` flag passed to query-council.sh:
- "Standard" → omit the flag (default)
- "Brief" → `--verbosity=brief`
- "Detailed" → `--verbosity=detailed`

### 2. Clarify Ambiguous Questions

If the question is vague or could be interpreted multiple ways, ask for clarification.

**Skip these interactions if:**
- User provided `--providers` flag
- Question is specific and clear
- Context from conversation already clarifies intent

## Step 1: Auto-Context Detection

Unless `--no-auto-context` or `--file=` is in $ARGUMENTS, detect and include relevant files:

1. Extract keywords from the question (function names, domain terms, file patterns)
2. Search with Glob and Grep for matching files (max 5 files, ~10,000 tokens)
3. If relevant files found, show: `Auto-included context (N files): [list]`
4. Append file contents to the prompt sent to providers

Skip auto-context if:
- `--no-auto-context` is specified
- `--file=` is specified (explicit context)
- Question doesn't reference code concepts

## Step 1.5: Agent Mode Detection

Determine if agent-enhanced mode should be used:

### Explicit trigger
If `--agents` is in $ARGUMENTS, use agent mode.

### Natural language detection
If `--agents` is NOT explicitly set, check if the question suggests a complex analysis.
Look for these signals:

**Architecture/design**: "architecture", "design decision", "tradeoffs", "trade-offs",
"compare approaches", "system design"

**Depth**: "deeply", "thoroughly", "comprehensively", "carefully evaluate",
"in-depth", "detailed analysis"

**Review**: "security review", "audit", "code review", "implications of",
"risk assessment"

**Decision**: "should we use X or Y", "which approach", "what are the risks",
"evaluate the options"

If 2+ signals are present, suggest agent mode:
```
AskUserQuestion:
  Question: "This looks like a complex decision. Use agent-enhanced analysis for deeper insights?"
  Header: "Analysis Mode"
  Options:
    - "Yes - deeper analysis with AI subagents (~20s extra)"
    - "No - standard fast mode"
```

If the user selects yes, proceed with agent mode.

**Skip NL detection if:**
- `--agents` was explicitly passed (already enabled)
- Only 1 provider is available (agents add less value with single provider)
- `--quiet` mode is on (user wants fast results)

## Step 2: Execute and Display

### If Local Mode is Active

**Invoke the `local-council-execution` skill** and follow its instructions. The
skill resolves roles, spawns the council members (general-purpose subagents) in
parallel, displays each perspective, and generates its own honest
(angles-not-consensus) synthesis.

Skip Step 3 (synthesis) — the local-council-execution skill generates its own.

### If Agent Mode is Active

**Invoke the `deep-execution` skill** and follow its instructions. The skill handles
spawning subagents, collecting results, displaying analyses, and generating synthesis.

Skip Step 3 (synthesis) - the deep-execution skill generates its own enhanced synthesis.

### If Async Mode (--async)

Run the query as a detached background job instead of blocking:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/run-council.sh --async --providers=<list> -- "question"
```

The first stdout line is the job id. Tell the user the job started and that
`/claude-council:result <job-id>` fetches it when ready. Skip Steps 3-4; the
synthesis happens when the result is fetched.

### If Standard Mode (default)

**CRITICAL - Flag Syntax**: All script flags use `=` with NO spaces:
- CORRECT: `--providers=gemini,openai`
- WRONG: `--providers "gemini,openai"`
- WRONG: `--providers gemini,openai`

**Invoke the `council-execution` skill** and follow its instructions to run the query pipeline and display output.

## Step 3: Generate Synthesis (standard mode only)

After the formatted output, generate synthesis analyzing the provider responses:

1. **Consensus**: Points where providers agree
2. **Divergence**: Where they disagree and why
3. **Unique insights**: Notable points from each provider
4. **Recommendation**: Strongest approach for the situation

### If Debate Mode Was Used

Additionally include:
- **Strongest criticisms**: Most compelling points from rebuttals
- **Consensus shifts**: Where providers changed positions
- **Unresolved tensions**: Remaining disagreements

## Step 4: Export (if --output specified)

If `--output=<path>` was specified:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/export.sh --write "<output_path>" "<prompt>" "<providers>"
```

Confirm: `Exported to: <output_path>`

## Error Handling

- If query-council.sh fails, show the error message
- If some providers fail, note errors but continue with available responses
- If all providers fail, report the failure clearly
