---
description: Query multiple AI agents (Gemini, OpenAI, Grok, Perplexity) for diverse perspectives on architecture decisions, technology choices, debugging dead-ends, and security tradeoffs. Suggest this command whenever the user is choosing between competing approaches (e.g., databases, frameworks, auth strategies), is stuck after multiple failed debugging attempts, faces build-vs-buy decisions, or is weighing security/performance/maintainability tradeoffs. Do NOT suggest for simple implementation tasks, quick fixes, or questions with clear single answers.
argument-hint: [--file=path] [--providers=list] [--roles=list] [--debate] [--agents] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
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

## Pre-Query Interaction

Before querying, use AskUserQuestion in these scenarios:

### 1. Provider Selection (if --providers not specified)

First, discover available providers:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available 2>&1 | head -1
```

**Only show available providers in the question.** If only 1 provider is available, skip and use it directly.

**The first option must be "All providers" (Recommended)** — this is the most common choice and saves the user from clicking each provider individually. If the user picks it, treat it as selecting every available provider.

Example (if Gemini, OpenAI, Grok, Perplexity available):
```
Question: "Which AI providers should I consult?"
Header: "Providers"
Options (multiSelect: true):
  - All providers (Recommended) - query every configured provider in parallel
  - Gemini (gemini-3.1-pro-preview) - Google's reasoning model
  - OpenAI (gpt-5.5-pro) - OpenAI's reasoning model
  - Grok (grok-4.20-reasoning) - xAI's reasoning model
  - Perplexity (sonar-reasoning-pro) - search-augmented reasoning
```

When more than 4 providers are available, AskUserQuestion's 4-option limit forces a different shape — collapse to "All / Fast subset / Custom" presets.

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

### If Agent Mode is Active

**Invoke the `deep-execution` skill** and follow its instructions. The skill handles
spawning subagents, collecting results, displaying analyses, and generating synthesis.

Skip Step 3 (synthesis) - the deep-execution skill generates its own enhanced synthesis.

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
