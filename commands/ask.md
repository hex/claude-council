---
description: Query multiple AI agents for diverse perspectives on a coding problem
argument-hint: [--file=path] [--providers=list] [--roles=list] [--debate] [--output=path] [--quiet] [--no-cache] [--no-auto-context] "question"
allowed-tools: Bash(*), Read, Glob, Grep, AskUserQuestion
---

Query the council of AI coding agents to gather diverse perspectives.

## Pre-Query Interaction

Before querying, use AskUserQuestion in these scenarios:

### 1. Provider Selection (if --providers not specified)

First, discover available providers:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh --list-available 2>&1 | head -1
```

**Only show available providers in the question.** If only 1 provider is available, skip and use it directly.

Example (if Gemini and OpenAI available):
```
Question: "Which AI providers should I consult?"
Header: "Providers"
Options (multiSelect: true):
  - Gemini (gemini-3-flash-preview) - Google's fast reasoning model
  - OpenAI (codex-mini-latest) - OpenAI's code-focused model
```

### 2. Clarify Ambiguous Questions

If the question is vague or could be interpreted multiple ways, ask for clarification.

Signs of ambiguity:
- Question lacks specific context (e.g., "What's the best approach?")
- Multiple valid interpretations exist
- Missing key details (language, framework, scale, constraints)

Example:
```
Question: "What aspect should I focus the council's attention on?"
Header: "Focus"
Options:
  - Architecture & design patterns
  - Performance optimization
  - Security considerations
  - Code quality & maintainability
```

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

## Step 2: Execute Query

Run the council query with all user arguments:

```bash
JSON_OUTPUT=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/query-council.sh $ARGUMENTS 2>&1)
```

The script handles:
- Argument parsing and validation
- Role injection (--roles)
- Debate mode two-round execution (--debate)
- Response caching
- Parallel provider queries

Returns structured JSON with `metadata`, `round1`, and optionally `round2`.

## Step 3: Format Output

Display formatted results:

```bash
echo '$JSON_OUTPUT' | bash ${CLAUDE_PLUGIN_ROOT}/scripts/format-output.sh
```

IMPORTANT: Show the exact terminal output. Do not reformat, summarize, or recreate the headers.

The formatter handles:
- Provider boxes with colors, emojis, models, roles
- Quiet mode (--quiet skips individual responses)
- Debate mode round headers and rebuttals
- Synthesis header

## Step 4: Generate Synthesis

After the formatted output, generate synthesis analyzing the provider responses.

Parse the JSON to understand:
- Which providers responded (check `.round1` keys)
- Assigned roles (check `.round1[provider].role`)
- Whether debate mode was used (check `.metadata.debate_mode`)

### Synthesis Content

Create a synthesis section with:

1. **Consensus**: Points where providers agree - use a summary table:
   | Topic | Provider 1 | Provider 2 | Provider 3 | Consensus? |
   |-------|------------|------------|------------|------------|

2. **Divergence**: Where providers disagree and why

3. **Unique insights**: Notable points from each provider (color provider names!)

4. **Recommendation**: Which approach seems strongest for the situation

### If Debate Mode Was Used

Additionally include:
- **Strongest criticisms**: Most compelling points from rebuttals
- **Consensus shifts**: Where providers changed positions
- **Unresolved tensions**: Remaining disagreements

### Header Format

When referencing providers in synthesis, use bar-style headers:
```
━━━ 🔵 GEMINI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ gemini-3-flash-preview
━━━ ⚪ OPENAI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ codex-mini-latest
━━━ 🔴 GROK ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━ grok-4-1-fast-reasoning
━━━ ⚡ SYNTHESIS ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Provider colors in text:
- Gemini: Blue
- OpenAI: Gray/dim
- Grok: Red

## Step 5: Export (if --output specified)

Check `.metadata.output_path` in the JSON. If set:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/lib/export.sh --write "<output_path>" "<prompt>" "<providers>"
```

After writing, confirm: `Exported to: <output_path>`

## Error Handling

- If query-council.sh fails, show the error message
- If some providers fail, note errors but continue with available responses
- If all providers fail, report the failure clearly
